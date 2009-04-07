package Resmon::Status;

use strict;
use POSIX qw/:sys_wait_h/;
use IO::Handle;
use IO::File;
use IO::Socket;
use Socket;
use Fcntl qw/:flock/;
use IPC::SysV qw /IPC_PRIVATE IPC_CREAT IPC_RMID ftok S_IRWXU S_IRWXG S_IRWXO/;
use Data::Dumper;

my $SEGSIZE = 1024*256;
my $KEEPALIVE_TIMEOUT = 5;
my $REQUEST_TIMEOUT = 60;
sub new {
  my $class = shift;
  my $file = shift;
  return bless {
    file => $file
  }, $class;
}
sub get_shared_state {
  my $self = shift;
  my $blob;
  my $len;
  return unless(defined($self->{shared_state}));
  # Lock shared segment
  # Read in
  shmread($self->{shared_state}, $len, 0, length(pack('i', 0)));
  $len = unpack('i', $len);
  shmread($self->{shared_state}, $blob, length(pack('i', 0)), $len);
  # unlock
  my $VAR1;
  eval $blob;
  die $@ if ($@);
  $self->{store} = $VAR1;
  return $self->{store};
}
sub store_shared_state {
  my $self = shift;
  return unless(defined($self->{shared_state}));
  my $blob = Dumper($self->{store});

  # Lock shared segment
  # Write state and flush
  shmwrite($self->{shared_state}, pack('i', length($blob)),
           0, length(pack('i', 0))) || die "$!";
  shmwrite($self->{shared_state}, $blob, length(pack('i', 0)),
           length($blob)) || die "$!";
  # unlock
}
sub xml_kv_dump {
  my $info = shift;
  my $indent = shift || 0;
  my $rv = '';
  while(my ($key, $value) = each %$info) {
    $rv .= " " x $indent;
    if(ref $value eq 'HASH') {
      $rv .= "<$key>\n";
      $rv .= xml_kv_dump($value, $indent + 2);
      $rv .= " " x $indent;
      $rv .= "</$key>\n";
    }
    else {
      $value =~ s/&/&amp;/g;
      $value =~ s/</&lt;/g;
      $value =~ s/>/&gt;/g;
      $value =~ s/'/&apos;/g;
      $rv .= "<$key>$value</$key>\n";
    }
  }
  return $rv;
}
sub xml_info {
  my ($module, $service, $info) = @_;
  my $rv = '';
  $rv .= "  <ResmonResult module=\"$module\" service=\"$service\">\n";
  $rv .= xml_kv_dump($info, 4);
  $rv .= "  </ResmonResult>\n";
  return $rv;
}
sub dump_generic {
  my $self = shift;
  my $dumper = shift;
  my $rv = '';
  while(my ($module, $services) = each %{$self->{store}}) {
    while(my ($service, $info) = each %$services) {
      $rv .= $dumper->($module,$service,$info);
    }
  }
  return $rv;
}
sub dump_generic_module {
  # Dumps a single module rather than all checks
  my $self = shift;
  my $dumper = shift;
  my $module = shift;
  my $rv = '';
  my $services = $self->{store}->{$module};
  while(my ($service, $info) = each %$services) {
    $rv .= $dumper->($module,$service,$info);
  }
  return $rv;
}
sub dump_generic_state {
  # Dumps only checks with a specific state
  my $self = shift;
  my $dumper = shift;
  my $state = shift;
  my $rv = '';
  while(my ($module, $services) = each %{$self->{store}}) {
    while(my ($service, $info) = each %$services) {
      if ($info->{state} eq $state) {
        $rv .= $dumper->($module,$service,$info);
      }
    }
  }
  return $rv;
}
sub dump_oldstyle {
  my $self = shift;
  my $response = $self->dump_generic(sub {
    my($module,$service,$info) = @_;
    return "$service($module) :: $info->{state}($info->{message})\n";
  });
  return $response;
}
sub dump_xml {
  my $self = shift;
  my $response = <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="/resmon.xsl"?>
<ResmonResults>
EOF
  ; 
  $response .= $self->dump_generic(\&xml_info);
  $response .= "</ResmonResults>\n";
  return $response;
}
sub get_xsl() {
  my $response = <<EOF
<?xml version="1.0" encoding="ISO-8859-1"?>
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:template match="ResmonResults">
<html>
<head>
    <title>Resmon Results</title>
    <link rel="stylesheet" type="text/css" href="/resmon.css" />
</head>
<body>
    <ul class="navbar">
        <li><a href="/">List all checks</a></li>
        <li><a href="/BAD">List all checks that are BAD</a></li>
        <li><a href="/WARNING">List all checks that are WARNING</a></li>
        <li><a href="/OK">List all checks that are OK</a></li>
    </ul>
    <xsl:for-each select="ResmonResult">
        <div class="item">
                <xsl:attribute name="class">
                    item <xsl:value-of select="state" />
                </xsl:attribute>
            <ul class="info">
                <li>Time taken for last check:
                    <xsl:value-of select="last_runtime_seconds" /></li>
                <li>Last updated:
                    <xsl:value-of select="last_update" /></li>
            </ul>
            <h1>
                <a>
                    <xsl:attribute name="href">
                        /<xsl:value-of select="\@module" />
                    </xsl:attribute>
                    <xsl:value-of select="\@module" />
                </a>
                -
                <a>
                    <xsl:attribute name="href">
                        /<xsl:value-of select="\@module"
                            />/<xsl:value-of select="\@service" />
                    </xsl:attribute>
                    <xsl:value-of select="\@service" />
                </a>
            </h1>
            <h2>
                <xsl:value-of select="state"/>:
                <xsl:value-of select="message" />
            </h2>
            <a class="config" href="#">
                Hover to view configuration...
                <table>
                    <tr>
                        <th>Name</th>
                        <th>Value</th>
                    </tr>
                    <xsl:for-each select="configuration/*">
                        <tr>
                            <td><xsl:value-of select="name(.)" /></td>
                            <td><xsl:value-of select="." /></td>
                        </tr>
                    </xsl:for-each>
                </table>
            </a>
        </div>
    </xsl:for-each>
</body>
</html>
</xsl:template>
</xsl:stylesheet>
EOF
  ;
  return $response;
}
sub get_css() {
  my $response=<<EOF
body {
    font-family: Verdana, Arial, helvetica, sans-serif;
}
h1 {
    margin: 0;
    font-size: 120%;
}

h2 {
    margin: 0;
    font-sizE: 110%;
}

.item {
    border: 1px solid black;
    padding: 1em;
    margin: 2em;
    background-color: #eeeeee;
}

a.config {
    color: black;
}

a.config:visited {
    color: black;
}

a.config table {
    display: none
}

a.config:hover table {
    display: block;
    position: fixed;
    top: 1em;
    right: 1em;
    max-width: 95%;
    overflow: hidden;
}

.info {
    float: right;
    font-size: 80%;
    padding: 0;
    margin: 0;
}

.OK {
    background-color: #afa;
}

.WARNING {
    background-color: #ffa;
}

.BAD {
    background-color: #faa;
}

table {
    border: 1px solid black;
    background-color: #eeeeee;
    border-collapse: collapse;
    margin: 1em;
    font-size: 80%;
}

th {
    font-size: 100%;
    font-weight: bold;
    background-color: black;
    color: white;
}

td {
    padding-left: 1em;
    padding-right: 1em;
}

a {
    text-decoration: none;
}

ul.navbar {
    list-style: none;
    font-size: 80%;
}
ul.navbar li {
    display: inline;
    padding-left: 1em;
    padding-right: 1em;
    margin-right: -1px;
    border-left: 1px solid black;
    border-right: 1px solid black;
}
EOF
  ;
  return $response;
}
sub service {
  my $self = shift;
  my ($client, $req, $proto, $snip) = @_;
  my $state = $self->get_shared_state();
  if($req eq '/' or $req eq '/status') {
    my $response .= $self->dump_xml();
    $client->print(http_header(200, length($response), 'text/xml', $snip));
    $client->print($response . "\r\n");
    return;
  } elsif($req eq '/status.txt') {
    my $response = $self->dump_oldstyle();
    $client->print(http_header(200, length($response), 'text/plain', $snip));
    $client->print($response . "\r\n");
    return;
  } elsif($req eq '/resmon.xsl') {
    my $response = $self->get_xsl();
    $client->print(http_header(200, length($response), 'text/xml', $snip));
    $client->print($response . "\r\n");
    return;
  } elsif($req eq '/resmon.css') {
    my $response = $self->get_css();
    $client->print(http_header(200, length($response), 'text/css', $snip));
    $client->print($response . "\r\n");
    return;
  } elsif($req =~ /^\/([^\/]+)\/(.+)$/) {
    if(exists($self->{store}->{$1}) &&
        exists($self->{store}->{$1}->{$2})) {
    my $info = $self->{store}->{$1}->{$2};
    my $response = qq^<?xml version="1.0" encoding="UTF-8"?>\n^;
    my $response .= qq^<?xml-stylesheet type="text/xsl" href="/resmon.xsl"?>^;
    $response .= "<ResmonResults>\n".
                    xml_info($1,$2,$info).
                    "</ResmonResults>\n";
    $client->print(http_header(200, length($response), 'text/xml', $snip));
    $client->print( $response . "\r\n");
    return;
    }
  } elsif($req =~ /^\/([^\/]+)$/) {
    if ($1 eq "BAD" || $1 eq "OK" || $1 eq "WARNING") {
      my $response = qq^<?xml version="1.0" encoding="UTF-8"?>\n^;
      my $response .= qq^<?xml-stylesheet type="text/xsl" href="/resmon.xsl"?>^;
      $response .= "<ResmonResults>\n".
                      $self->dump_generic_state(\&xml_info,$1) .
                      "</ResmonResults>\n";
      $client->print(http_header(200, length($response), 'text/xml', $snip));
      $client->print( $response . "\r\n");
      return;
    } elsif(exists($self->{store}->{$1})) {
      my $response = qq^<?xml version="1.0" encoding="UTF-8"?>\n^;
      my $response .= qq^<?xml-stylesheet type="text/xsl" href="/resmon.xsl"?>^;
      $response .= "<ResmonResults>\n".
                      $self->dump_generic_module(\&xml_info,$1) .
                      "</ResmonResults>\n";
      $client->print(http_header(200, length($response), 'text/xml', $snip));
      $client->print( $response . "\r\n");
      return;
    }
  }
  die "Request not understood\n";
}
sub http_header {
  my $code = shift;
  my $len = shift;
  my $type = shift || 'text/xml';
  my $close_connection = shift || 1;
  return qq^HTTP/1.0 $code OK
Server: resmon
^ . (defined($len) ? "Content-length: $len\n" : "") .
    (($close_connection || !$len) ? "Connection: close\n" : "") .
qq^Content-Type: $type; charset=utf-8

^;
}
sub serve_http_on {
  my $self = shift;
  my $ip = shift;
  my $port = shift;
  $ip = INADDR_ANY if(!defined($ip) || $ip eq '' || $ip eq '*');
  $port ||= 81;

  my $handle = IO::Socket->new();
  socket($handle, PF_INET, SOCK_STREAM, getprotobyname('tcp'))
    || die "socket: $!";
  setsockopt($handle, SOL_SOCKET, SO_REUSEADDR, pack("l", 1))
    || die "setsockopt: $!";
  bind($handle, sockaddr_in($port, $ip))
    || die "bind: $!";
  listen($handle,SOMAXCONN);

  $self->{zindex} = 0;
  if (-x "/usr/sbin/zoneadm") {
    open(Z, "/usr/sbin/zoneadm list -p |");
    my $firstline = <Z>;
    close(Z);
    ($self->{zindex}) = split /:/, $firstline, 2;
  }
  $self->{http_port} = $port;
  $self->{http_ip} = $ip;
  $self->{ftok_number} = $port * (1 + $self->{zindex});

  $self->{child} = fork();
  if($self->{child} == 0) {
    eval {
      $SIG{'HUP'} = 'IGNORE';
      while(my $client = $handle->accept) {
        my $req;
        my $proto;
        my $close_connection;
        local $SIG{ALRM} = sub { die "timeout\n" };
        eval {
          alarm($KEEPALIVE_TIMEOUT);
          while(<$client>) {
            alarm($REQUEST_TIMEOUT);
            eval {
              s/\r\n/\n/g;
              chomp;
              if(!$req) {
                if(/^GET \s*(\S+)\s*?(?: HTTP\/(0\.9|1\.0|1\.1)\s*)?$/) {
                  $req = $1;
                  $proto = $2;
                  # Protocol 1.1 and high are keep-alive by default
                  $close_connection = ($proto <= 1.0)?1:0;
                }
                elsif(/./) {
                  die "protocol deviations.\n";
                }
              }
              else {
                if(/^$/) {
                  $self->service($client, $req, $proto, $close_connection);
                  last if ($close_connection);
                  alarm($KEEPALIVE_TIMEOUT);
                  $req = undef;
                  $proto = undef;
                }
                elsif(/^\S+\s*:\s*.{1,4096}$/) {
                  # Valid request header... noop
                  if(/^Connection: (\S+)/) {
                    if(($proto <= 1.0 && lc($2) eq 'keep-alive') ||
                       ($proto == 1.1 && lc($2) ne 'close')) {
                      $close_connection = 0;
                    }
                  }
                }
                else {
                  die "protocol deviations.\n";
                }
              }
            };
            if($@) {
              print $client http_header(500, 0, 'text/plain', 1);
              print $client "$@\r\n";
              last;
            }
          }
          alarm(0);
        };
        alarm(0) if($@);
        $client->close();
      }
    };
    if($@) {
      print STDERR "Error in listener: $@\n";
    }
    exit(0);
  }
  close($handle);
  return;
}
sub open {
  my $self = shift;
  return 0 unless(ref $self);
  return 1 if($self->{handle});  # Alread open
  if($self->{file} eq '-' || !defined($self->{file})) {
    $self->{handle_is_stdout} = 1;
    $self->{handle} = IO::File->new_from_fd(fileno(STDOUT), "w");
    return 1;
  }
  $self->{handle} = IO::File->new("> $self->{file}.swap");
  die "open $self->{file}.swap failed: $!\n" unless($self->{handle});
  $self->{swap_on_close} = 1; # move this to a non .swap version on close
  chmod 0644, "$self->{file}.swap";

  unless(defined($self->{shared_state})) {
    $self->{shared_state} = shmget(IPC_PRIVATE, $SEGSIZE,
                                   IPC_CREAT|S_IRWXU|S_IRWXG|S_IRWXO);
    die "$0: $!" if($self->{shared_state} == -1);
  }
  return 1;
}
sub store {
  my ($self, $type, $name, $info) = @_;
  %{$self->{store}->{$type}->{$name}} = %$info;
  $self->{store}->{$type}->{$name}->{last_update} = time;
  $self->store_shared_state();
  if($self->{handle}) {
    $self->{handle}->print("$name($type) :: $info->{state}($info->{message})\n");
  } else {
    print "$name($type) :: $info->{state}($info->{message})\n";
  }
}
sub purge {
    # This removes status information for modules that are no longer loaded

    # Generate list of current modules
    my %loaded = ();
    my ($self, $config) = @_;
    while (my ($type, $mods) = each(%{$config->{Module}}) ) {
        $loaded{$type} = ();
        foreach (@$mods) {
            $loaded{$type}{$_->{'object'}} = 1;
        }
    }

    # Debugging
    #while (my ($key, $value) = each(%loaded) ) {
    #    print STDERR "$key: ";
    #    while (my ($mod, $dummy) = each (%$value) ) {
    #        print STDERR "$mod ";
    #    }
    #    print "\n";
    #}

    # Compare $self->{store} with list of loaded modules
    while (my ($type, $value) = each (%{$self->{store}})) {
        while (my ($name, $value2) = each (%$value)) {
            if (!exists($loaded{$type}) || !exists($loaded{$type}{$name})) {
                #print STDERR "$type $name\n";
                delete $self->{store}->{$type}->{$name};
                if (scalar(keys %{$self->{store}->{$type}}) == 0) {
                    #print STDERR "$type has no more objects, deleting\n";
                    delete $self->{store}->{$type};
                }
            }
        }
    }
}
sub close {
  my $self = shift;
  return if($self->{handle_is_stdout});
  $self->{handle}->close() if($self->{handle});
  $self->{handle} = undef;
  if($self->{swap_on_close}) {
    unlink("$self->{file}");
    link("$self->{file}.swap", $self->{file});
    unlink("$self->{file}.swap");
    delete($self->{swap_on_close});
  }
}
sub DESTROY {
  my $self = shift;
  my $child = $self->{child};
  if($child) {
    kill 15, $child;
    sleep 1;
    kill 9, $child if(kill 0, $child);
    waitpid(-1,WNOHANG);
  }
  if(defined($self->{shared_state})) {
    shmctl($self->{shared_state}, IPC_RMID, 0);
  }
}
1;
