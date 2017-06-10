package vCardTools;

use Moose;


sub parse_file {
    my( $self, $vcf_path ) = @_;
    open( my $fh_in, '<', $vcf_path ) or die( "$vcf_path: $!" );

    # Get text blocks from file for each vcard
    my $text = '';
    my @vcards_text;
    while( my $line = readline( $fh_in ) ){
        next if( $line =~ m/^BEGIN:VCARD/ );
        if( $line =~ m/^END:VCARD/ ){
            if( $text =~ m/^\s*$/s ){
                print "BEGIN:VCARD\n";
                print $text;
                print "END:VCARD\n";
                die( "Empty Vcard at $." );
            }
            push( @vcards_text, $text );
            $text = '';
            next;
        }
        $text .= $line;
    }
    close $fh_in;
    printf "Got %u cards\n", scalar( @vcards_text );

    # Convert the text blocks into a hashref
    my @vcards;
    foreach my $text( @vcards_text ){
        my @lines = split( "\r\n", $text );
        #print Dump( \@lines );
        my $vcard = {};
        my $previous_key = undef;
        foreach my $line( @lines ){
            if( $line =~ m/^([^ ].*?):(.*)$/m ){
                my ( $key, $value ) = ( $1, $2 );
                $previous_key = $key;
                if( $key and $value ){
                    if( $vcard->{$key} ){
                        push( @{ $vcard->{$key} }, $value );
                    }else{
                        $vcard->{$key} = [ $value ];
                    }
                }
            }elsif( $previous_key and $line =~ m/^ (.*)/ ){
                $vcard->{$previous_key}[ scalar( @{ $vcard->{$previous_key}} ) - 1 ] .= $1;
            }else{
                die( "Unparseable line: $line\nVcard:\nBEGIN:VCARD\n$text\nEND:VCARD\n" );
            }
        }
        push( @vcards, $vcard );
    }
    return @vcards;
}


1;

=head1 NAME


=head1 DESCRIPTION


=head1 METHODS

=over 4


=back

=head1 COPYRIGHT

Copyright 2011, Robin Clarke, Munich, Germany

=head1 AUTHOR

Robin Clarke <perl@robinclarke.net>

