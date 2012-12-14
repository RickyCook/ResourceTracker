#!/usr/bin/perl -w

use warnings;
use strict;

use Data::Dumper;
use List::Util qw(min);
use List::MoreUtils qw(firstidx);
use POSIX qw(strftime);
use Scalar::Util qw(looks_like_number);

use constant DISK    => 1;
use constant MEM     => DISK << 1;
use constant CPU     => MEM << 1;

use constant ENABLED     => DISK|MEM|CPU;
use constant DELAY       => 1;
use constant DATE_FORMAT => '%Y-%m-%d %T';

sub get_simple_line_callback {
	my ($match_regex, $indexes, $split_regex) = @_;
	$split_regex ||= '\s';

	return sub {
		my ($_) = @_;

		# Only care about a set of lines
		return unless /$match_regex/;

		# Split (usually at whitespace)
		my @split = grep { !($_ eq '') } split /$split_regex/;

		# Return columns
		return @split[@$indexes];
	},
}
sub get_kv_line_callback {
	my ($match_regexes, $value_pos, $split_regex) = @_;
	$split_regex ||= '\s';

	return sub {
		my ($line) = @_;

		# Get the index that matches the regex (if any)
		my $idx = firstidx { $line =~ /$_/ } @$match_regexes;
		return unless defined $idx && $idx >= 0;

		# Split (usually at whitespace)
		my @split = grep { !($_ eq '') } split /$split_regex/, $line;

		# Set the correct array value at index
		my @return = ();
		$return[$idx] = $split[$value_pos];
		return @return;
	}
}

use constant JOBS => [
	{
		id   => DISK(),
		name => 'Disk I/O',
		out_filename  => 'r-disk.csv',
		in_filename   => '/proc/diskstats',
		total_cols    => [qw(read_sectors read_millis write_sectors write_millis total_millis)],
		summary_lines => [
			'READ:  sector count: %read_sectors%, time spent: %read_millis% ms',
			'WRITE: sector count: %write_sectors%, time spent: %write_millis% ms',
			'TOTAL: time spent: %total_millis% ms',
		],
		line_callback => get_simple_line_callback('(sd|hd|sr)', [5,6,9,10,12]),
	},
	{
		id   => MEM(),
		name => 'Memory',
		out_filename  => 'r-mem.csv',
		in_filename   => '/proc/meminfo',
		total_cols    => [qw(free_mem free_swap)],
		summary_lines => [
			'FREE: RAM: %free_mem% kB, swap: %free_swap% kB',
		],
		line_callback => get_kv_line_callback([qw(MemFree SwapFree)], 1),
	},
	{
		id => CPU(),
		name => 'CPU',
		out_filename  => 'r-cpu.csv',
		in_filename   => '/proc/stat',
		total_cols    => [qw(user nice system idle iowait)],
		summary_lines => [
			'PROCESSES: user: %user%, nice: %nice%, system: %system%',
			'WAITING:   idle: %idle%, IO wait: %iowait%',
		],
		line_callback => get_simple_line_callback('cpu[0-9]+', [2,3,4,5,6]),
	},
];

sub flush {
	my ($fh) = @_;

	my $old = select($fh);
	$|++;
	select($old);

	return $old;
}

foreach my $job (@{JOBS()}) {
	if (ENABLED & $job->{id}) {
		print sprintf "Logging %s to %s\n", $job->{name}, $job->{out_filename};

		# Open job-specific file handle
		open $job->{out_fh}, '>', $job->{out_filename} or die $!;

		# CSV headers
		print {$job->{out_fh}} (join ',', 'datetime', @{$job->{total_cols}}) . "\n";
		flush($job->{out_fh});
	}
}

sub add_to_totals {
	my ($data, $totals, $columns) = @_;

	# Total the results
	my $settable_count = min(scalar @$data, scalar @{$columns});
	for (my $i = 0; $i < $settable_count; $i++) {
		if (defined $data->[$i]) {

			my $totals_col_ref = \($totals->{$columns->[$i]});
			my $both_numeric = looks_like_number($data->[$i]) && looks_like_number($$totals_col_ref);

			if (!$both_numeric) {
				if (defined $$totals_col_ref) {
					$$totals_col_ref = join ',',
						$$totals_col_ref,
						$data->[$i];
				} else {
					$$totals_col_ref = $data->[$i];
				}
			} else {
				$$totals_col_ref ||= 0;
				$$totals_col_ref += $data->[$i];
			}
		}
	}
}

while (1) {
	my $dtstring = strftime(DATE_FORMAT,localtime);
	print sprintf "============== %s SECOND DELAY (%s) ==============\n", DELAY, $dtstring;
	foreach my $job (@{JOBS()}) {
		if (ENABLED & $job->{id}) {
			open IN, '<', $job->{in_filename} or die $!;

			my %totals = ();

			# Loop through all rows in the file and total results of line callback
			if (defined $job->{line_callback}) {
				while (<IN>) {
					my @row_data = $job->{line_callback}->($_);
					next unless (@row_data);
					add_to_totals(\@row_data, \%totals, $job->{total_cols});
				}
			}

			# Do the once only callback
			if (defined $job->{once_callback}) {
				my @row_data = $job->{once_callback}->();
				next unless (@row_data);
				add_to_totals(\@row_data, \%totals, $job->{total_cols});
			}

			# Output the line to CSV
			my @csv_data = map { $totals{$_} || 0 } @{$job->{total_cols}};
			print {$job->{out_fh}} (join ',', $dtstring, @csv_data) . "\n";
			flush($job->{out_fh});

			# Print summary to screen
			print sprintf "-- %s SUMMARY (LOGGED) --\n", uc $job->{name};
			foreach my $line_format (@{$job->{summary_lines}}) {
				my $line = $line_format;
				foreach my $column (@{$job->{total_cols}}) {
					my $data = $totals{$column} || 0;
					$line =~ s/%$column%/$data/g;
				}
				print $line . "\n";
			}
		}
	}

	sleep DELAY;
	print "\n";
}