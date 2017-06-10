#!/usr/bin/env perl

use strict;
use warnings;
use YAML qw/Dump LoadFile DumpFile/;
use JSON qw/encode_json/;
use File::Temp qw/tempdir/;
use Getopt::Long;
use Template;
use vCardTools;
use LWP::UserAgent;
use File::Spec::Functions; # catfile
use Geo::Coder::Google;

my %params;
GetOptions( \%params,
    'config=s',
);

# Load config
foreach( qw/config/ ){
    if( not $params{$_} ){
        die( "Required parameter missing: $_\n" );
    }
}
die( "Config file does not exist: $params{config}\n" ) if( not -f $params{config} );
my $config = LoadFile( $params{config} );

# Create a temp dir to work in
my $temp_dir = tempdir( CLEANUP => 1 );
printf "Temp dir: $temp_dir\n";

# Template toolkit config
my %tt_config = (
    INCLUDE_PATH => './'
);

my $ua = LWP::UserAgent->new(
    keep_alive => 1
    );

$ua->credentials( sprintf( "%s:%u", $config->{domain}, $config->{port} ), $config->{realm},
    $config->{username}, $config->{password} );

my $uri = sprintf( "http%s://%s:%u/remote.php/dav/addressbooks/users/%s/%s/?export", 
   ( $config->{is_https} ? 's' : '' ),
        $config->{domain},
        $config->{port},
        $config->{username},
        $config->{contacts}{address_book}
        );
my $filename_vcf = catfile( $temp_dir, 'source.vcf' );

print "Downloading contacts\n";
my $response = $ua->get( $uri, ':content_file' => $filename_vcf );
if( not $response->is_success ){
    die( "Failed: \n" . Dump( $response ) );
}

print "Processing cards to markdown\n";
my $vcard_tools = vCardTools->new();

my @cards = $vcard_tools->parse_file( $filename_vcf );
my @cards_cleaned;
foreach my $card ( @cards ){

    if( not $card->{N} ){
        print "Skippoing card because no 'N' field:\n";
        print Dump( $card );
        next;
    }
    my( $surname, $firstname ) = split( ';', $card->{N}[0] );
    my $new_card = {
        phone_home  => ( $card->{'TEL;TYPE=HOME\,VOICE'} ?  $card->{'TEL;TYPE=HOME\,VOICE'}[0] : undef ),
        phone_cell  => ( $card->{'TEL;TYPE=CELL'} ?  $card->{'TEL;TYPE=CELL'}[0] : undef ),
        email       => ( $card->{'EMAIL;TYPE=HOME'} ?  $card->{'EMAIL;TYPE=HOME'}[0] : undef ),
        birthday    => ( $card->{'BDAY'} ?  $card->{'BDAY'}[0] : undef ),
        title       => ( $card->{'TITLE'} ?  $card->{'TITLE'}[0] : undef ),
        email       => ( $card->{'EMAIL;TYPE=HOME'} ?  $card->{'EMAIL;TYPE=HOME'}[0] : undef ),
        surname     => $surname,
        firstname   => $firstname,
    };

    if( $card->{'ADR;TYPE=HOME'} ){
        my ( $post_office, undef, $street, $city, $state, $postcode, $country ) = split( ';',$card->{'ADR;TYPE=HOME'}[0] );
        $new_card->{address} = {
            street      => $street,
            city        => $city,
            state       => $state,
            postcode    => $postcode,
            country     => $country,
        };
        $new_card->{address_string} = $card->{'ADR;TYPE=HOME'}[0];
    }
    push( @cards_cleaned, $new_card );
}
@cards = @cards_cleaned;

@cards = sort { $a->{surname} cmp $b->{surname} } @cards;

# Write out a JSON file (for logstash processing)
if( $config->{contacts}{json_file} ){
    my $geo_cache = {};
    my $geocoder;

    if( $config->{contacts}{geo_cache} ){
        $geocoder = Geo::Coder::Google->new( apiver => 3 );
        if( -f $config->{contacts}{geo_cache} ){
            $geo_cache = LoadFile( $config->{contacts}{geo_cache} );
        }
    }
    open( my $fh_json, '>', $config->{contacts}{json_file} ) or die( $! );
    binmode( $fh_json );
    foreach my $card( @cards ){
        if( $geocoder and $card->{address} ){
            my $address_string = sprintf( "%s, %s %s, %s",
                    $card->{address}{street},
                    $card->{address}{postcode},
                    $card->{address}{city},
                    $card->{address}{country},
                    );
            my $location = $geo_cache->{$address_string};
            if( not $location ){
                $location = $geocoder->geocode( location => $address_string );
                $geo_cache->{$address_string} = $location;
            }
            $card->{location}{lat} = $location->{geometry}{location}{lat};
            $card->{location}{lon} = $location->{geometry}{location}{lng};
        }
        print $fh_json encode_json( $card ) . "\n";
    }
    if( $config->{contacts}{geo_cache} ){
        DumpFile( $config->{contacts}{geo_cache}, $geo_cache );
    }
    close $fh_json;
}
my $filename_markdown = catfile( $temp_dir, 'output.markdown' );
open( my $fh_out, '>', $filename_markdown )  or die( "Could not open out ($filename_markdown): $!\n" );

# Go through the list of cards (already sorted by surname) and for each (postal)
# address find all others with the same address
my @cards_left;
while( scalar( @cards ) > 0 ){
    @cards_left = ();
    my @cards_block;
    # Get the address of the first card
    my $card =  $cards[0];
    my $address_string = $card->{address_string};
    my $address = $card->{address};
    push( @cards_block, $card );

    # All of the surnames to store
    my %surnames;
    my %home_phones;
    $home_phones{$card->{phone_home}}++ if $card->{phone_home};
    $surnames{$card->{surname}}++;
    foreach( 1 .. $#cards ){
        $card = $cards[$_];
        if( $address_string and $card->{address_string} and $card->{address_string} eq $address_string ){
            $surnames{$card->{surname}}++;
            $home_phones{$card->{phone_home}}++ if $card->{phone_home};
            push( @cards_block, $card );
        }else{
            push( @cards_left, $card );
        }
    }

    my $vars = {
        home_phones     => [ keys %home_phones ],
        surnames        => [ sort keys %surnames ],
        address         => $address,
        cards   => [ sort { $a->{title} cmp $b->{title} || $a->{firstname} cmp $b->{firstname} }@cards_block ],
    };
    
    my $markdown;
    my $tt = Template->new( \%tt_config ) or die( Template->error(), "\n" );
    $tt->process( 'family.markdown', $vars , \$markdown ) || die( $tt->error() );
    print $fh_out $markdown;
    @cards = @cards_left;
}
close $fh_out;


print "Converting to pdf\n";
my @pandoc_variables = (
    'geometry:top=1cm',
    'geometry:left=2cm',
    'geometry:right=2cm',
    'geometry:bottom=2cm',
    'papersize:a4paper',
    'mainfont="Arial"',
    );
my $filename_pdf = catfile( $temp_dir, 'output.pdf' );
my $exec_to_pdf = "pandoc $filename_markdown -f markdown";
foreach( @pandoc_variables ){
    $exec_to_pdf .= ' --variable ' . $_;
}
$exec_to_pdf .= " -o $filename_pdf";
printf "%s\n", $exec_to_pdf;
print `$exec_to_pdf`;

# Now upload the calendar
if( $config->{contacts}{upload_file} ){
    print "Uploading\n";
    my $uri = sprintf( "http%s://%s:%u/remote.php/webdav/%s", 
        ( $config->{is_https} ? 's' : '' ),
        $config->{domain},
        $config->{port},
        $config->{contacts}{upload_file}
        );
    open( my $fh_pdf, '<:utf8', $filename_pdf ) or die( "Could not open pdf: $!" );
    binmode( $fh_pdf );
    my $pdf_data;
    while( my $line = readline( $fh_pdf ) ){
        $pdf_data .= $line;
    }
    close $fh_pdf;
    my $response = $ua->put( $uri, Content => $pdf_data );
    if( not $response->is_success ){
        die( "Failed: \n" . Dump( $response ) );
    }
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

