#!/usr/bin/perl

use Modern::Perl;
use utf8;
use open qw(:encoding(UTF-8) :std);
use FindBin qw($Bin);
use lib ("$Bin/Notable/lib", "$Bin/Text-BibLaTeX/lib");
use Notable;
use Text::BibLaTeX;
use Text::Unidecode;
use YAML::PP qw(LoadFile);
use Getopt::Long;
use Storable qw(freeze);
use File::Temp;
use IPC::Open3;
use URI::Encode qw(uri_encode);

# Get options
my $Debug     = 0;
my $MaxNotes  = 9999; # maximum number of notes to process in one run
my $Overwrite = 0;
my $Sort      = 0;
my $Test      = 0;
my $Verbose   = 0;
my @Bibliography;
my @CSL;
GetOptions(
    'bibliography=s' => \@Bibliography,
    'csl=s'          => \@CSL,
    'debug'          => \$Debug,
    'overwrite'      => \$Overwrite,
    'maxnotes=i'     => \$MaxNotes,
    'sort'           => \$Sort,
    'test'           => \$Test,
    'verbose'        => \$Verbose,
) || die "Invalid command line options";

$Verbose        = 1 if ($Debug);
$Notable::DEBUG = $Debug;

@CSL = qw(apa chicago-note-bibliography) unless (@CSL);

my $Command = shift @ARGV;

my $Usage = <<END;

Usage: notable-bibtex [options] <import | export | citeproc | update>

Valid options:

  --bibliography=<file> Use bibliography.
  --verbose             Verbose output.
  --debug               Debugging output.
  --test                Never write any files.
END

my $DDC = []; # global variable to hold the DDC lookup table

# Create Notable object
my $Notable = Notable->new(".");

if ( !$Command ) {
    say STDERR "No command specified";
    say $Usage;
}
elsif ( $Command =~ m/^import$/i ) {
    &import;
}
elsif ( $Command =~ m/^export$/i ) {
    &export;
}
elsif ( $Command =~ m/^cite(?:proc)?$/i ) {
    &citeproc;
}
elsif ( $Command =~ m/^update$/i ) {
    &update;
}
else {
    say STDERR "Invalid command '$Command'";
    say STDERR $Usage;
}
$Notable->close_dir;

# Search the Notable database for a note that matches the supplied
# Text::BibLaTeX::Entry. First, try to find the BibTeX key in the YAML
# metadata as bibtex->_key. If that fails, attempt to search the note title
# based on author, year and title. If that fails as well, create a new note.
sub find_note {
    my $bibtex_entry = shift;
    my $bibtex_key   = $bibtex_entry->key;

    # First, try the BibTeX key. This should work.
    say "find_note: lookup $bibtex_key" if ($Debug);
    my @notes = $Notable->select_meta( 'bibtex->_key' => $bibtex_key );

    # If we found exactly one note, this is the one.
    if ( scalar @notes == 1 ) {
        say "find_note: found key $bibtex_key" if ($Verbose);
        return $notes[0];
    }

    # If we found several notes, it means we have two notes with the same
    # BibTeX key in the Notable database, and we don't know which one to
    # update.
    elsif ( scalar @notes > 1 ) {
        say STDERR "find_note: duplicate key '$bibtex_key' in Notable database, please correct";
        foreach my $n (@notes) {
            say STDERR "  - note ", $n->file;
        }
        return undef;
    }

    # try old way
    say "find_note: lookup $bibtex_key (old way)" if ($Debug);
    @notes = $Notable->select_meta( 'bibtex_key' => $bibtex_key );
    if ( scalar @notes == 1 ) {
        say "find_note: found key $bibtex_key" if ($Verbose);
        return $notes[0];
    }
    elsif ( scalar @notes > 1 ) {
        say STDERR "find_note: duplicate key '$bibtex_key' in Notable database, please correct";
        foreach my $n (@notes) {
            say STDERR "  - note ", $n->file;
        }
        return undef;
    }

    # If no note with a matching BibTeX key was found, try to search based on
    # author, year and title (because that's what the note title is supposed
    # to look like).
    if ( $bibtex_entry->has('title') ) {

        # get title, remove everything but alphanumeric and whitespace and
        # turn it into a search pattern
        my $title = $bibtex_entry->field('title');
        $title =~ s/[^\s\w]//g;
        $title =~ s/\s+/.*/g;

        # Get first author or editor.
        my @a;
        if ( $bibtex_entry->has('author') ) {
            @a = $bibtex_entry->author;
        }
        elsif ( $bibtex_entry->has('editor') ) {
            @a = $bibtex_entry->editor;
        }
        my $author = $a[0]->last if (@a);

        # get year
        my $year = $bibtex_entry->year;

        my $regex = join( '.*', grep {$_} ( $author, $year, $title ) );

        #print Data::Dumper->Dump( [ $author, $year, $title, $regex ], [qw(author year title regex)] );

        # try to find a single note now
        say "find_note: lookup title regex='$regex'" if ($Debug);
        @notes = $Notable->select_title($regex);

        # if we found exactly one note, this is the one
        if ( scalar @notes == 1 ) {
            say "find_note: found title ", $notes[0]->title if ($Verbose);
            return $notes[0];
        }

        # if we found several notes, something is very wrong and we shouldn't continue
        elsif ( scalar @notes > 1 ) {
            say STDERR "find_note: title search returned ambiguous result:";
            foreach my $n (@notes) {
                say STDERR "  - note ", $n->file;
            }
            return undef;
        }
        else {

            # Sanitize title.
            my $title = $bibtex_entry->field('title');
            $title =~ s/(?<![{\w])(\w+)(?![}\w])/lc( $1 )/eg;    # convert to lowercase
            $title =~ s/[{}\$"]//g;                              # remove invalid characters
            $title =~ s/(?:''|``)//g;                            # remove double quotes - why?
            $title =~ s/\s+--\s+.*//;                            # remove dashes - why?
            $title =~ s/--/-/g;                                  # convert double dashes
            $title = ucfirst($title);                            # first character uppercase

            # Get authors or editors
            my $author = $bibtex_entry->has('author') ? $bibtex_entry->author_string("last") : '';
            if ( !$author ) {
                $author = $bibtex_entry->has('editor') ? $bibtex_entry->editor_string("last") : '';
            }

            # Get year
            my $year = $bibtex_entry->year;

            # Now we can put together the expected note title
            my $notetitle;
            if ( $author && $year && $title ) {
                $notetitle = "$author ($year) $title";
            }
            elsif ( $author && $title ) {
                $notetitle = "$author (ND) $title";
            }
            elsif ( $year && $title ) {
                $notetitle = "$title ($year)";
            }
            else {
                $notetitle = $title;
            }

            # Some more sanitizing
            $notetitle =~ s/[\{\}\\\$]//g;
            $notetitle =~ s/’/'/g;

            # create file name and do some cleaning
            my $filename = unidecode( substr( $notetitle, 0, 120 ) . '.md' );
            $filename =~ s/[\?\/<>]//g;
            $filename =~ s/  +/ /g;

            # create a Notable note
            my $note = $Notable->add_note( title => $notetitle, file => $filename, overwrite => 1 );

            if ($note) {
                say "find_note: created new note '", $note->file, "'" if ($Verbose);
            }
            return $note;
        }
    }
    else {
        say STDERR "No key found for '$bibtex_key' and entry has no title";
        return undef;
    }
}

sub import {
    foreach my $bibfile (@Bibliography) {
        say "import: processing $bibfile" if ($Verbose);
        my $bibdb = Text::BibLaTeX::DB->new($bibfile);
        if ( $bibdb->ok ) {
            say "import: read ", $bibdb->entries(), " entries" if ($Verbose);
            my $notebook = ucfirst($bibfile);
            $notebook =~ s/\.bib//;
            while ( my $entry = $bibdb->next ) {
                my $note = find_note($entry);

                unless ($note) {
                    say STDERR "import: could not find ", $entry->key;
                    next;
                }

                my $orig_metadata = freeze( $note->{meta} );

                # add entire bibtex entry as metadata
                #my @keys = grep { !m/^_/ } keys %{$entry};
                #my %bibtex_entry;
                #@bibtex_entry{@keys} = @{$entry}{@keys};
                #$bibtex_entry{_key}  = $entry->key;
                #$bibtex_entry{_type} = lc( $entry->type );
                #$note->meta( bibtex => \%bibtex_entry );
                foreach my $key ( grep { !m/^_/ } keys %{$entry} ) {
                    $note->meta( "bibtex->$key", $entry->{$key} );
                }
                $note->meta( "bibtex->_key",  $entry->key );
                $note->meta( "bibtex->_type", lc( $entry->type ) );

                # Remove BibTeX key and type; it's stored in the 'bibtex' key from now on
                $note->delete_meta('bibtex_key');
                $note->delete_meta('bibtex_type');

                # add files
                if ( $entry->has('file') ) {
                    foreach my $file ( $entry->files ) {
                        my $path = $file->path;
                        my ( $vol, $dir, $file ) = File::Spec->splitpath($path);
                        $note->add_attachments($file);
                    }
                    delete $note->{meta}->{bibtex}->{file};
                }

                # # relevance?
                # if ( $entry->has('relevance') ) {
                #     $note->add_tags( "Relevance/" . $entry->field('relevance') );
                #     delete $note->{meta}->{bibtex}->{relevance};
                # }

                # remove timestamp
                delete $note->{meta}->{bibtex}->{timestamp};

                # remove some other stuff
                #delete $note->{meta}->{bibtex}->{qualityassured};
                #delete $note->{meta}->{bibtex}->{collectionid};

                # add some contents if it doesn't exist or only exists of a simple title
                my $content = $note->content;
                if ( !$content || $content =~ m/^\s*$/s || $content =~ m/^#[^\n]*\n*$/s ) {
                    print Data::Dumper->Dump( [$content], [qw(content)] );
                    my $content = "# " . $note->title . "\n\n<!--ref begin-->\n<!--ref end-->\n";
                    if ( $entry->has('abstract') ) {
                        $content .= "\n## Sammanfattning\n\n> " . $entry->field('abstract') . "\n";
                        delete $note->{meta}->{bibtex}->{abstract};
                    }
                    if ( $entry->has('comment') ) {
                        $content .= "\n## Kommentar\n\n" . $entry->field('comment') . "\n";
                        delete $note->{meta}->{bibtex}->{comment};
                    }
                    say STDERR "import: add content" if ($Debug);
                    $note->content($content);
                }

                #print Data::Dumper->Dump( [$note], [qw(note)]);

                my $new_metadata = freeze( $note->{meta} );

                # write the note
                if ( $orig_metadata ne $new_metadata ) {
                    if ($Test) {
                        say "import: would write '", $note->file, "' (testing only)";
                    }
                    else {
                        say "import: write '", $note->file, "'" if ($Verbose);
                        $note->write;
                    }
                }
            }
            say "import: finished $bibfile" if ($Verbose);
        }
        else {
            say STDERR "import: failed $bibfile: ", $bibdb->error;
        }
    }
}

sub export {
    if ( @Bibliography == 1 ) {
        say "export: exporting to ", $Bibliography[0];
        my $bibdb = Text::BibLaTeX::DB->new();
        foreach my $note ( $Notable->select_all ) {
            if ( $note->has('bibtex') ) {
                my $bibtex_key = $note->meta('bibtex->_key');
                $bibtex_key = $note->meta('bibtex_key') if ( !$bibtex_key );
                my $bibtex_type = $note->meta('bibtex->_type');
                $bibtex_type = $note->meta('bibtex_type') if ( !$bibtex_type );
                if ( !$bibtex_key ) {
                    say STDERR "export: no BibTeX key for ", $note->file;
                    next;
                }
                if ( !$bibtex_type ) {
                    say STDERR "export: no BibTeX type for $bibtex_key";
                    next;
                }
                my $entry = Text::BibLaTeX::Entry->new( $bibtex_type, $bibtex_key, 1, $note->{meta}->{bibtex} );
                $bibdb->add($entry);

                #print Data::Dumper->Dump( [$entry, $note], [qw(entry note)] );
            }
        }

        $bibdb->sort if ($Sort);
        say "export: write ", $Bibliography[0];
        $bibdb->write( $Bibliography[0] );
    }
    else {
        say STDERR "Must specify exactly one bibliography with --bibliography";
        say STDERR $Usage;
        exit 2;
    }
}

###############################################################################
## Citation processing
##

sub citeproc {

    # write bibliography to temporary file (unless --bibliography has been set)
    unless ( scalar @Bibliography == 1 ) {
        my $fh = File::Temp->new( SUFFIX => '.bib' );
        $Bibliography[0] = $fh;
    }
    export;

    my $counter = 0;
    foreach my $note ( $Notable->select_all ) {
        if ( $note->has('bibtex->_key') ) {
            say "citeproc: processing ", $note->title if ($Verbose);
            my $changed;
            foreach my $csl (@CSL) {

                if ( $note->has("reference->$csl") && !$Overwrite ) {
                    say STDERR "citeproc: skipping existing reference $csl" if ($Debug);
                    next;
                }

                # create reference
                my $cmd = "pandoc -t markdown-citations-smart --citeproc --wrap=none --bibliography=$Bibliography[0] --csl=$csl";

                say STDERR "citeproc: running '$cmd'" if ($Debug);
                my ( $pandoc, $markdown, $err );
                use Symbol 'gensym';
                $err = gensym;
                my $pid = open3( $pandoc, $markdown, $err, $cmd );
                die "citeproc: open3() fail" unless ($pid);

                # Write to pandoc
                print $pandoc "---\n";
                print $pandoc "nocite: |\n  @", $note->meta('bibtex->_key'), "\n";
                print $pandoc "...\n";
                close $pandoc;
                my $ref = "";

                # Read from pandoc
                binmode $markdown, ":encoding(UTF-8)";
                while (<$markdown>) {
                    next if ( m/^</ || m/^\s*$/ || m/^::/ );
                    chomp;
                    $ref .= $_;
                }
                close $markdown;

                # Read errors
                print STDERR "citeproc: pandoc error: $_" while (<$err>);
                close $err;
                waitpid( $pid, 0 );

                say "citeproc: ", $ref if ($Debug);

                if ($ref) {
                    $note->meta( "reference->$csl", $ref ) if ($ref);
                    $note->delete_meta("ref");
                    $note->modified_now;
                    $changed = 1;
                }
            }

            #print Data::Dumper->Dump( [$note], [qw(note)] );
            if ($changed && !$Test) {
                $counter++;
                say "citeproc: write ", $note->file, " (", $counter, ")";
                $note->modified_now;
                $note->write;
                last if ($counter>=$MaxNotes);
            }
        }
    }
}

###############################################################################
## Updating existing note
##

sub set_subtags {
    my ($note, $tag, @subtags) = @_;

    # list of existing tags
    my %existing_tags = map { $_ => 1 } grep { m:^$tag: } $note->tags;
    
    # list of added tags
    my %wanted_tags = map { $tag . '/' . $_ => 1 } @subtags;

    # flag to keep track of changes
    my $changed;

    # add non-existing tags
    my @add_tags =  grep {!$existing_tags{$_}} keys %wanted_tags;
    if (@add_tags) {
        say STDERR "update: add tags: ", join( ", ", @add_tags) if ($Verbose);
        $note->add_tags( @add_tags );
        $changed = 1;
    }

    # remove unwanted tags
    my @remove_tags = grep {!$wanted_tags{$_}} keys %existing_tags;
    if (@remove_tags) {
        say STDERR "update: remove tags: ", join( ", ", @remove_tags) if ($Verbose);
        $note->remove_tags( @remove_tags );
        $changed = 1;
    }

    return $changed;
}

sub parse_ddc {
    my $ddc = shift;
    my $ddc_string = "";
    for my $i (1..3) {
        my $ddc_part = substr $ddc, 0, $i;
        if ($DDC->{$ddc_part}) {
            $ddc_string .= '/' if ($ddc_string);
            $ddc_string .= "$ddc_part $DDC->{$ddc_part}";
        }
    }
    return $ddc_string;
}

sub update {
    # read ddc classifications
    if (-f "DDC.yaml") {
        $DDC = LoadFile( "DDC.yaml");
    }   
    my $counter = 0;
    foreach my $note ( $Notable->select_all ) {
        if ( $note->has('bibtex') ) {
            say "update: ", $note->title if ($Verbose);

            # Get content of note
            my $content = my $orig_content = $note->content;

            # remove crlf
            $content =~ s/\r(?=\n)//gs;

            # Flag if anything is changed during the process
            my $changed;

            # Flag if reference block should be replaced eve if it exists
            my $replace_ref_block = $Overwrite;    # flag

            # we want an entire block with bibiographical data, make sure there is one
            unless ( $content =~ m:^<!--\s*ref.*?-->.*?<!--\s*ref.*?-->:ms ) {

                # remove old bibliography section
                $content =~ s:^<!--\s*bibliography.*?-->.*?<!--\s*/bibliography.*?-->::ms;

                # remove old files section
                $content =~ s:^<!--\s*files\s*-->.*?<!--\s*/files\s*-->::ms;

                # remove bibtex section
                $content =~ s:^```biblatex.*?```::ms;

                # add block just below main title
                unless ( $content =~ s/^(#.*?\n)/$1\n<!--ref begin-->\n<!--ref end-->\n\n/s ) {
                    die "Failed to add new ref block";
                }

                # now do replace the block
                $replace_ref_block = 1;
            }

            # replace block if we should
            if ($replace_ref_block) {
                say STDERR "update: replacing ref block" if ($Debug);
                my $ref_block = '';

                if ( $note->has('reference') ) {
                    foreach my $ref ( sort keys %{ $note->meta('reference') } ) {
                        my $style;
                        if ( $ref =~ m/^apa/ ) {
                            $style = 'APA';
                        }
                        elsif ( $ref =~ m/^chicago/ ) {
                            $style = 'Chicago';
                        }
                        else {
                            $style = $ref;
                        }
                        $ref_block .= $style . "\n: " . $note->meta("reference->$ref") . "\n\n";
                    }
                }

                if ( $note->has('attachments') ) {

                    # make inline links
                    my $links = '';
                    $links .= "![](\@attachment/" . uri_encode($_) . ")\n\n" foreach ( $note->attachments );

                    # add links
                    $ref_block .= $links;
                }

                # replace the ref block
                $content =~ s:^<!--\s*ref.*?-->.*?<!--\s*ref.*?-->:<!--ref begin-->\n\n$ref_block<!--ref end-->:ms;

                # remove excessive newlines
                $content =~ s/(?<=\n\n)\n+//gs;

                # remove newlines at end
                $content =~ s/(?<=\n)\n+$//s;

                #print STDERR Data::Dumper->Dump( [ $content, $ref_block ], [qw(content ref_block)] );

                # if something changed, set flag
                $changed = 1 if ( $content ne $orig_content );

                say STDERR "update: reference block replaced" if ($Debug);
            }

            # add BibTeX type as tag
            if ($note->has('bibtex->_type')) {
                if (set_subtags($note, "Type", ucfirst($note->meta('bibtex->_type')))) {
                    $changed = 1;
                }
            }

            # add author and editor names as tags
            my @authors;
            foreach my $names ( $note->meta('bibtex->author'), $note->meta('bibtex->editor') ) {
                if ($names) {
                    foreach my $name ( split m/\s+and\s+/, $names ) {
                        my @name      = Text::BibLaTeX::Author->split($name);
                        for my $i (0..$#name) {
                            $name[$i] =~ s:[{}]::g if ($name[$i]);
                        }
                        my $lastfirst = $name[1] ? $name[1] . ' ' : '';
                        $lastfirst .= $name[2];
                        $lastfirst .= ', ' . $name[3] if ( $name[3] );
                        $lastfirst .= ', ' . $name[0] if ( $name[0] );
                        my $firstchar = uc substr $lastfirst, 0, 1;
                        push @authors, "$firstchar/$lastfirst";
                    }
                }
            }
            if (set_subtags( $note, "Author", @authors )) {
                $changed = 1;
            }

            # add journal title as tag
            if ( $note->has('bibtex->journaltitle') ) {
                my $journal = $note->meta('bibtex->journaltitle');
                $journal =~ s/[{}\$"\\]//g;    # remove invalid characters
                if (set_subtags( $note, "Journal", $journal )) {
                    $changed = 1;
                }
            }

            # add ddc as tag
            if ( $note->has('bibtex->ddc') ) {
                if ($DDC->{'1'}) {
                    my $ddc = parse_ddc( $note->meta('bibtex->ddc'));
                    #$ddc =~ s:\.:/:g;
                    if (set_subtags( $note, "DDC", $ddc )) {
                        $changed = 1;
                    }
                }
            }
            else {
                if (set_subtags( $note, "DDC")) {
                    $changed = 1;
                }
            }

            # add abstract to note -- this is a one time thing
            if ( $note->has('bibtex->abstract') ) {
                my $abstract = $note->meta('bibtex->abstract');
                if ( $content !~ m/\Q$abstract\E/ ) {
                    say STDERR "update: add abstract" if ($Verbose);
                    if ( $content =~ s/(?<=<!--ref end-->)/\n\n## Sammanfattning\n\n> $abstract/s ) {
                        $note->delete_meta('bibtex->abstract');
                        $changed = 1;
                    }
                    else {
                        say STDERR "update: failed to add abstract to ", $note->title;
                    }
                }
                else {
                    say STDERR "update: remove already existing abstract" if ($Verbose);
                    $note->delete_meta('bibtex->abstract');
                    $changed = 1;
                }
            }

            # add comment to note -- this is a one time thing
            if ( $note->has('bibtex->comment') ) {
                my $comment = $note->meta('bibtex->comment');
                if ( $content !~ m/\Q$comment\E/ ) {
                    say STDERR "update: add comment" if ($Verbose);
                    if ( $content =~ s/\n*$/\n\n## Kommentar\n\n$comment/s ) {
                        $note->delete_meta('bibtex->comment');
                        $changed = 1;
                    }
                    else {
                        say STDERR "update: failed to add comment to ", $note->title;
                    }
                }
                else {
                    say STDERR "update: remove already existing comment" if ($Verbose);
                    $note->delete_meta('bibtex->comment');
                    $changed = 1;
                }
            }

            # add keywords as tags
            if ( $note->has('bibtex->keywords') ) {
                my @keywords = map {"Keywords/$_"} split m/\s*[;,]\s*/, $note->meta('bibtex->keywords');
                $note->add_tags(@keywords);
                $note->delete_meta('bibtex->keywords');
                $changed = 1;
                say "update: add keywords";
            }

            # if it is marked important (from Jabref)
            if ( $note->has('bibtex->important') ) {
                if ( $note->meta('bibtex->important') eq 'true' ) {
                    $note->meta( 'favorited', 1 );
                    $changed = 1;
                    say "update: marked as important";
                }
                $note->delete_meta('bibtex->important');
            }

            # add projects as tags
            if ( $note->has('bibtex->project') ) {
                my @projects = map {"Projects/$_"} split m/\s*[;,]\s*/, $note->meta('bibtex->project');
                $note->add_tags(@projects);
                $note->delete_meta('bibtex->project');
                $changed = 1;
                say "update: add project";
            }

            # add courses as tags
            if ( $note->has('bibtex->course') ) {
                my @courses = map {"Courses/$_"} split m/\s*[;,]\s*/, $note->meta('bibtex->course');
                $note->add_tags(@courses);
                $note->delete_meta('bibtex->course');
                $changed = 1;
                say "update: add courses";
            }

            # remove placing, i don't need it and i don't want it
            if ( $note->has('bibtex->placing') ) {
                $note->delete_meta('bibtex->placing');
                $changed = 1;
                say "update: remove placing";
            }

            # remove more stuff I don't want
            if ( $note->has('bibtex->read') ) {
                $note->delete_meta('bibtex->read');
                $changed = 1;
                say "update: remove read";
            }
            if ( $note->has('bibtex->readstatus') ) {
                $note->delete_meta('bibtex->readstatus');
                $changed = 1;
                say "update: remove readstatus";
            }
            if ( $note->has('bibtex->ranking') ) {
                $note->delete_meta('bibtex->ranking');
                $changed = 1;
                say "update: remove ranking";
            }
            if ( $note->has('bibtex->priority') ) {
                $note->delete_meta('bibtex->priority');
                $changed = 1;
                say "update: remove priority";
            }
            if ( $note->has('bibtex->relevance') ) {
                $note->delete_meta('bibtex->relevance');
                $changed = 1;
                say "update: remove relevance";
            }
            if ( $note->has('bibtex->owner') ) {
                $note->delete_meta('bibtex->owner');
                $changed = 1;
                say "update: remove owner";
            }

            # write note if changed
            if ($changed) {
                $counter++;
                unless ($Test) {
                    say STDERR "update: writing ", $note->title, " (", $counter, ")";
                    $note->content($content);
                    $note->modified_now;
                    $note->write;
                }
                else {
                    say STDERR "update: NOT writing ", $note->title;
                }
                last if ($counter >= $MaxNotes);
            }
        }
    }
}
