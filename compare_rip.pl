#!/opt/csw/bin/perl

use warnings;
use strict;

# ----------------------------------------------------------
#

sub usage {
	print "usage: $0 <dir> <dir>\n";
	exit 255;
}

# ----------------------------------------------------------
#

if ( $#ARGV != 1 ) {
	usage();
}

my %directoryName = (
	"L" => $ARGV[0],
	"R" => $ARGV[1]
);

# ----------------------------------------------------------
#
my %blocks;

sub addBlock {
	my ( $id, $block ) = @_;

	if ( !defined ${$block}{"type"} ) {
		die "Block doesn't have a type.";
	}

	my $type = ${$block}{"type"};
	$type =~ s/\s.*//;
	if ( defined $blocks{$id}{$type} ) {
		die "Block type $type defined multiple times.";
	}
	%{ $blocks{$id}{$type} } = %{$block};
}

sub parseFlac {
	my ( $id, $file ) = @_;

	open( my $fh, "metaflac --list \"$file\" |" ) or die "$!: $file";

	my $state = 0;
	my %block;

	while ( my $line = <$fh> ) {
		chomp $line;

		if ( $line =~ m/^METADATA block #\d+$/ ) {

			if ( $state > 2 ) {
				addBlock( $id, \%block );
			}

			%block = ();
			$state = 1;

			next;
		}

		if ( $state == 2 ) {
			next;
		}

		if ( $state == 1 ) {
			if ( $line !~ m/\s*(.*):\s*(.*)/ ) {
				die "internal error";
			}
			my $key   = $1;
			my $value = $2;

			if ( $key ne "type" ) {
				die "first line is not \"type:\".";
			}
			if (       ( $value eq "0 (STREAMINFO)" )
				or ( $value eq "4 (VORBIS_COMMENT)" ) )
			{
				$state = 3;
			}
			elsif (    ( $value eq "3 (SEEKTABLE)" )
				or ( $value eq "6 (PICTURE)" )
				or ( $value eq "1 (PADDING)" ) )
			{

				# ignore
				$state = 2;
				next;
			}
			else {
				die "unknown block: $value";
			}
		}

		if ( $state == 3 ) {
			if ( $line =~ m/\s*(.*):\s*(.*)/ ) {
				if ( defined $block{$1} ) {
					die "overwriting $1: is $block{$1} new $2\n";
				}
				$block{$1} = $2;

				next;
			}
			else {
				die "Unknown entry in block.";
			}

			next;
		}

		die "internal error";
	}

	if ( $state == 0 ) {
		die "no block found, should never happen.";
	}

	close($fh) or die "$!";

	if ( $state > 2 ) {
		addBlock( $id, \%block );
	}
}

# ----------------------------------------------------------
#
sub parseDir {
	my ($dname) = @_;

	opendir( D, $dname ) or die "$!: $dname";

	my %files;
	while ( my $dent = readdir(D) ) {
		next if ( ( $dent eq '.' ) or ( $dent eq '..' ) );

		if ( $dent =~ m/.\.(m3u|cue|log|jpg)$/ ) {
			my $fileType = $1;

			if ( defined $files{$fileType} ) {
				die "Two $fileType files: $files{$fileType} <-> $dent";
			}
			$files{$fileType} = $dent;
			next;
		}
		elsif ( $dent =~ m/[^\d]*(\d+).*\.flac$/ ) {
			my $track = $1 + 0;
			if ( defined $files{"flac"}{$track} ) {
				die "Two flac files for track $track: " . $files{"flac"}{$track} . " <-> $dent";
			}
			$files{"flac"}{$track} = $dent;
			next;
		}

		die "unknown file: $dent";
	}

	closedir(D) or die "$!: $dname";

	return (%files);
}

# ----------------------------------------------------------
#

my %files;
%{ $files{"L"} } = parseDir( $directoryName{"L"} );
%{ $files{"R"} } = parseDir( $directoryName{"R"} );

for my $type ( "cue", "m3u", "log", "jpg" ) {
	if ( !defined $files{"L"}{$type} ) {
		if ( !defined $files{"R"}{$type} ) {
			print "<=> no $type file\n";
		}
		else {
			print "<== no $type file\n";
		}
	}
	elsif ( !defined $files{"R"}{$type} ) {
		print "==> no $type file\n";
	}
}

my %tracks;
foreach my $track ( keys %{ $files{"L"}{"flac"} }, keys %{ $files{"R"}{"flac"} } ) {
	$tracks{$track} = 1;
}

foreach my $track ( sort { $a <=> $b } keys %tracks ) {
	my $differencesFound = 0;

	if ( !defined $files{"L"}{"flac"}{$track} ) {
		print "<== track $track no flac file\n";
		next;
	}
	if ( !defined $files{"R"}{"flac"}{$track} ) {
		print "==> track $track no flac file\n";
		next;
	}

	%blocks = ();

	parseFlac( "L", $directoryName{"L"} . "/" . $files{"L"}{"flac"}{$track} );
	parseFlac( "R", $directoryName{"R"} . "/" . $files{"R"}{"flac"}{$track} );

	my %sections;
	foreach my $section ( keys %{ $blocks{"L"} }, keys %{ $blocks{"R"} } ) {
		$sections{$section} = 1;
	}

	foreach my $section ( sort { $a <=> $b } keys %sections ) {
		if ( !defined $blocks{"L"}{$section} ) {
			print "<== track $track section $section: missing\n";
			next;
		}
		elsif ( !defined $blocks{"R"}{$section} ) {
			print "==> track $track section $section: missing\n";
			next;
		}

		if ( $section == 0 ) {
			my %keys;
			foreach my $key ( keys %{ $blocks{"L"}{$section} }, keys %{ $blocks{"R"}{$section} } ) {
				$keys{$key} = 1;
			}

			foreach my $key ( sort keys %keys ) {
				if ( ( !defined $blocks{"L"}{$section}{$key} ) or ( !defined $blocks{"R"}{$section}{$key} ) ) {
					die "track $track section $section: key $key only in one file.";
				}

				if (       ( $key eq "maximum blocksize" )
					or ( $key eq "maximum framesize" )
					or ( $key eq "minimum blocksize" )
					or ( $key eq "minimum framesize" )
					or ( $key eq "is last" ) )
				{
					next;
				}

				if ( $blocks{"L"}{$section}{$key} ne $blocks{"R"}{$section}{$key} ) {
					print "<=> track $track section $section: $key differs: " . $blocks{"L"}{$section}{$key} . " <=> " . $blocks{"R"}{$section}{$key} . "\n";
					$differencesFound = 1;
				}
			}

			next;
		}

		if ( $section == 4 ) {
			my %keys;
			foreach my $key ( keys %{ $blocks{"L"}{$section} }, keys %{ $blocks{"R"}{$section} } ) {
				$keys{$key} = 1;
			}

			my %comments;
			foreach my $key ( sort keys %keys ) {
				if ( $key =~ m/^comment\[\d+\]$/ ) {
					foreach my $side ( "R", "L" ) {
						if ( defined $blocks{$side}{$section}{$key} ) {
							if ( $blocks{$side}{$section}{$key} =~ m/([^=]+)=(.*)/ ) {
								if ( $2 ne "" ) {
									$comments{$side}{$1} = $2;
								}
							}
							else {
								die "not key=value: " . $blocks{$side}{$section}{$key};
							}
						}
					}

					next;
				}

				if ( ( !defined $blocks{"L"}{$section}{$key} ) or ( !defined $blocks{"R"}{$section}{$key} ) ) {
					die "key $key only in one file.";
				}

				if (       ( $key eq "length" )
					or ( $key eq "vendor string" )
					or ( $key eq "comments" )
					or ( $key eq "is last" ) )
				{
					next;
				}

				if ( $blocks{"L"}{$section}{$key} ne $blocks{"R"}{$section}{$key} ) {
					print "<=> track $track section $section: $key differs: " . $blocks{"L"}{$section}{$key} . " <=> " . $blocks{"R"}{$section}{$key} . "\n";
					$differencesFound = 1;
				}
			}

			%keys = ();
			foreach my $key ( keys %{ $comments{"L"} }, keys %{ $comments{"R"} } ) {
				$keys{$key} = 1;
			}

			foreach my $key ( sort keys %keys ) {
				if (       ( $key eq 'REPLAYGAIN_ALBUM_GAIN' )
					or ( $key eq 'REPLAYGAIN_ALBUM_PEAK' )
					or ( $key eq 'REPLAYGAIN_REFERENCE_LOUDNESS' )
					or ( $key eq 'REPLAYGAIN_TRACK_GAIN' )
					or ( $key eq 'REPLAYGAIN_TRACK_PEAK' ) )
				{
					next;
				}

				my $skipIfOnlyInOneFile = 0;
				if (       ( $key eq 'DISCNUMBER' )
					or ( $key eq 'GENRE' )
					or ( $key eq 'MUSICBRAINZ_ALBUMARTISTID' )
					or ( $key eq 'MUSICBRAINZ_ALBUMID' )
					or ( $key eq 'MUSICBRAINZ_ARTISTID' )
					or ( $key eq 'MUSICBRAINZ_DISCID' )
					or ( $key eq 'MUSICBRAINZ_TRACKID' )
					or ( $key eq 'TOTALDISCS' )
					or ( $key eq 'TOTALTRACKS' ) )
				{
					$skipIfOnlyInOneFile = 1;
				}

				if ( !defined $comments{"L"}{$key} ) {
					if ( $skipIfOnlyInOneFile == 0 ) {
						print "==> track $track section $section: additional comment: $key=" . $comments{"R"}{$key} . "\n";
						$differencesFound = 1;
					}
				}
				elsif ( !defined $comments{"R"}{$key} ) {
					if ( $skipIfOnlyInOneFile == 0 ) {
						print "<== track $track section $section: additional comment: $key=" . $comments{"L"}{$key} . "\n";
						$differencesFound = 1;
					}
				}
				elsif ( $comments{"L"}{$key} ne $comments{"R"}{$key} ) {
					if ( $key eq 'TRACKNUMBER' ) {
						my $tl = $comments{"L"}{$key} + 0;
						my $tr = $comments{"R"}{$key} + 0;

						if ( $tl == $tr ) {
							next;
						}
					}

					print "<=> track $track section $section: comment $key differs: " . $comments{"L"}{$key} . " <=> " . $comments{"R"}{$key} . "\n";
					$differencesFound = 1;
				}
			}

			next;
		}

		die "Unhandled section $section";
	}

	if ( $differencesFound == 0 ) {
		print "=== track $track no differences\n";
	}
}

