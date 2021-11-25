use strict;
use warnings;
use File::Temp qw(tempdir);
use Net::EmptyPort qw(empty_port wait_port);
use POSIX ":sys_wait_h";
use Test::More;
use t::Util;

=begin comment

Notes on generating raw packet data
==

This test uses two raw packet datagrams,
- t/assets/quic-decryptable-initial.bin
- t/assets/quic-nondecryptable-initial.bin
and here is a procedure to recreate them.

0. First, this test assumes that a testing node (process) uses the following configurations (see below in spawn_h2o()).
- key-file: examples/h2o/server.key
- certificate-file: examples/h2o/server.crt
- SSL ticket session resumption: use t/40session-ticket/forever_ticket.yaml
- node_id: 1
- node mapping for node_id=2.
Save the configuration to h2o-quic-1.conf.

1. Launch h2o with the above settings (`h2o -c h2o-quic-1.conf`), and run `h2o-httpclient -3 localhost $port` while captureing the packet transfers using tcpdump
```
$ sudo tcpdump -i lo -w $file udp port $port
```

2. Open the packet capture file with Wireshark and save the UDP payload (`udp.payload` if wireshark >= 3.4) of the first packet (client->server).
This will be quic-decryptable-initial.bin.

3. Create another h2o configuration, mostly a copy from the above, except
- node_id: 2
and save it as h2o-quic-2.conf.

4. Launch h2o with h2o-quic-2.conf, and capture the packet trace as in step 1.

5. Open the capture file from step 4 and find the first server->client packet.
Its SCID is a CID generated by server, encapsulating node_id=2.

6. Copy the CID obtained from step 5 to t/quic-ndec-initial-gen.c as *DCID*.
Copy SCID from the capture obtained in step 2 to quic-ndec-initial-gen.c as *SCID*.
Compile & run quic-ndec-initial-gen.c.
This will generate quic-nondecryptable-initial.bin.

=end comment
=cut

check_dtrace_availability();

my $tempdir = tempdir(CLEANUP => 1);

my $quic_port = empty_port({
    host  => "127.0.0.1",
    proto => "udp",
});

my $server = spawn_h2o(<< "EOT");
listen:
  type: quic
  host: 127.0.0.1
  port: $quic_port
  ssl:
    key-file: examples/h2o/server.key
    certificate-file: examples/h2o/server.crt
ssl-session-resumption:
  mode: ticket
  ticket-store: file
  ticket-file: t/40session-ticket/forever_ticket.yaml
hosts:
  default:
    paths:
      /:
        file.dir: t/assets/doc_root
quic-nodes:
  self: 1
  mapping:
   1: "127.0.0.1:8443"
   2: "127.0.0.2:8443"
   3: "127.0.0.3:8443"
EOT

wait_port({port => $quic_port, proto => 'udp'});

# launch tracer for h2o server
my $tracer_pid = fork;
die "fork(2) failed:$!"
	unless defined $tracer_pid;
if ($tracer_pid == 0) {
	# child process, spawn bpftrace
	close STDOUT;
	open STDOUT, ">", "$tempdir/trace.out"
		or die "failed to create temporary file:$tempdir/trace.out:$!";
  if ($^O eq 'linux') {
    exec qw(bpftrace -v -B none -p), $server->{pid}, "-e", <<'EOT';
usdt::h2o:h3_packet_forward { printf("num_packets=%d num_bytes=%d\n", arg2, arg3); }
EOT
    die "failed to spawn bpftrace:$!";
  } else {
    exec(
			qw(unbuffer dtrace -p), $server->{pid}, "-n", <<'EOT',
:h2o::h3_packet_forward {
  printf("\nXXXXnum_packets=%d num_bytes=%d\n", arg2, arg3);
}
EOT
		);
    die "failed to spawn dtrace:$!";
  }
}

# wait until bpftrace and the trace log becomes ready
my $read_trace = get_tracer($tracer_pid, "$tempdir/trace.out");
if ($^O eq 'linux') {
  while ($read_trace->() eq '') {
    sleep 1;
  }
}
sleep 2;

# throw packets to h2o

# test1: throw non-decryptable Initial first
# Since it's not associated with any existing connections, h2o would pass it to `quicly_accept` and
# it would return QUICLY_ERROR_DECRYPTION_FAILED. Then h2o would try to forward the packet using DCID's node_id field.
system("perl", "t/udp-generator.pl", "127.0.0.1", "$quic_port", "t/assets/quic-nondecryptable-initial.bin") == 0 or die "Failed to launch udp-generator";

# test2: throw decryptable Initial first, then non-decryptable Initial next
# The first Initial would successfully create a new connection object inside h2o.
# Then the because second Initial's DCID doesn't match the first one's, h2o determines
# the packet should be for another node, and forwards it using DCID's node_id field.
system("perl", "t/udp-generator.pl", "127.0.0.1", "$quic_port", "t/assets/quic-decryptable-initial.bin", "t/assets/quic-nondecryptable-initial.bin") == 0 or die "Failed to launch udp-generator";

# shutdown h2o
undef $server;

my $trace;
do {
	sleep 1;
} while (($trace = $read_trace->()) eq '');

# both test 1 and 2 emit single line of "num_packets=1 num_bytes=1280".
# FIXME: would be nicer to distinguish two tests from their outputs.
like $trace, qr{num_packets=1 num_bytes=1280.num_packets=1 num_bytes=1280}s;

# wait for the tracer to exit
while (waitpid($tracer_pid, 0) != $tracer_pid) {}

done_testing;
