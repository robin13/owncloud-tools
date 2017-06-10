#!/usr/bin/env perl

use strict;
use warnings;
use YAML qw/Dump LoadFile/;
use Getopt::Long;
use LWP::UserAgent;
use Encode qw/encode_utf8 decode_utf8/;

my %params;
GetOptions( \%params,
    'config=s',
);

foreach( qw/config/ ){
    if( not $params{$_} ){
        die( "Required parameter missing: $_\n" );
    }
}
die( "Config file does not exist: $params{config}\n" ) if( not -f $params{config} );
my $config = LoadFile( $params{config} );

my $ua = LWP::UserAgent->new(
    keep_alive => 1
    );

$ua->credentials( sprintf( "%s:%u", $config->{domain}, $config->{port} ), $config->{realm},
    $config->{username}, $config->{password} );

my $target_headers_done = undef;
my $ical = '';
foreach my $calendar_name( @{ $config->{calendar}{calendars} } ){
    printf "Working on $calendar_name\n";
    my $prefix = $config->{calendar}{prefix_map}{$calendar_name} || '';
    my $uri = sprintf( "http%s://%s:%u/remote.php/dav/calendars/%s/%s?export", 
        ( $config->{is_https} ? 's' : '' ),
        $config->{domain},
        $config->{port},
        $config->{username},
        $calendar_name
        );
    my $response = $ua->get( $uri );
    if( not $response->is_success ){
        die( "Failed: \n" . Dump( $response ) );
    }

    my $calendar_headers_done = 0;
    my @lines = split( "\r\n", $response->decoded_content );
    my $line_number = 0;
    my $skip_line = 0;
    while( $line_number < $#lines ){
        $skip_line = 0;
        my $line = $lines[$line_number];
        if( not $target_headers_done and $line ne 'BEGIN:VEVENT' ){
            if( $line =~ m/^X\-WR\-CALNAME/ ){
                $line = "X-WR-CALNAME:$config->{calendar}{target_calendar_name}";
            }
            if( $line =~ m/^X\-APPLE-CALENDAR-COLOR/ ){
                $skip_line = 1;
            }
        }elsif( not $calendar_headers_done and $line ne 'BEGIN:VEVENT' ){
            $skip_line = 1;
        }elsif( not $calendar_headers_done and $line eq 'BEGIN:VEVENT' ){
            $calendar_headers_done = 1;
            $target_headers_done = 1;
        }
        
        if( $prefix ){
            $line = sprintf( "%s:%s: %s", $1, $prefix, $2 ) if( $line =~ m/^(SUMMARY|DESCRIPTION):(.*)$/ );
        }
        if( not $skip_line ){
            $ical .= $line . "\r\n";
        }
        $line_number++;
    }
}
$ical .= "END:VCALENDAR\r\n";
$ical = encode_utf8( $ical );

# Now upload the calendar
if( $config->{calendar}{upload_file} ){
    print "Uploading\n";
    my $uri = sprintf( "http%s://%s:%u/remote.php/webdav/%s", 
        ( $config->{is_https} ? 's' : '' ),
        $config->{domain},
        $config->{port},
        $config->{calendar}{upload_file}
        );
    my $response = $ua->put( $uri, Content => $ical );
    if( not $response->is_success ){
        print "Failed upload\n\n" . Dump( $response );
        exit;
    }
}
if( $config->{calendar}{output_file} ){
    print "Writing to file\n";
    open( my $fh, '>', $config->{calendar}{output_file} ) or die( $! );
    print $fh $ical;
    close $fh;
}


exit( 0 );

=head1 NAME

Program name - one line description

=head1 SYNOPSIS



=head1 DESCRIPTION



=head1 OPTIONS

=over 4

=item --option

option description


=back

=head1 COPYRIGHT

Copyright 2015, Robin Clarke

=head1 AUTHOR

Robin Clarke C<perl@robinclarke.net>

=cut

