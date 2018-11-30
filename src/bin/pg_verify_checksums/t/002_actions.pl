# Do basic sanity checks supported by pg_verify_checksums using
# an initialized cluster.

use strict;
use warnings;
use PostgresNode;
use TestLib;
use Test::More tests => 36;

# Initialize node with checksums enabled.
my $node = get_new_node('node_checksum');
$node->init(extra => ['--data-checksums']);
my $pgdata = $node->data_dir;

# Control file should know that checksums are enabled.
command_like(['pg_controldata', $pgdata],
	     qr/Data page checksum version:.*1/,
		 'checksums enabled in control file');

# These are correct but empty files, so they should pass through.
append_to_file "$pgdata/global/99999", "";
append_to_file "$pgdata/global/99999.123", "";
append_to_file "$pgdata/global/99999_fsm", "";
append_to_file "$pgdata/global/99999_init", "";
append_to_file "$pgdata/global/99999_vm", "";
append_to_file "$pgdata/global/99999_init.123", "";
append_to_file "$pgdata/global/99999_fsm.123", "";
append_to_file "$pgdata/global/99999_vm.123", "";

# Checksums pass on a newly-created cluster
command_ok(['pg_verify_checksums',  '-D', $pgdata],
		   "succeeds with offline cluster");

# Checks cannot happen with an online cluster
$node->start;
command_fails(['pg_verify_checksums',  '-D', $pgdata],
			  "fails with online cluster");

# Create table to corrupt and get its relfilenode
$node->safe_psql('postgres',
	"SELECT a INTO corrupt1 FROM generate_series(1,10000) AS a;
	ALTER TABLE corrupt1 SET (autovacuum_enabled=false);");

my $file_corrupted = $node->safe_psql('postgres',
	"SELECT pg_relation_filepath('corrupt1')");
my $relfilenode_corrupted =  $node->safe_psql('postgres',
	"SELECT relfilenode FROM pg_class WHERE relname = 'corrupt1';");

# Set page header and block size
my $pageheader_size = 24;
my $block_size = $node->safe_psql('postgres', 'SHOW block_size;');
$node->stop;

# Checksums are correct for single relfilenode as the table is not
# corrupted yet.
command_ok(['pg_verify_checksums',  '-D', $pgdata,
	'-r', $relfilenode_corrupted],
	"succeeds for single relfilenode with offline cluster");

# Time to create some corruption
open my $file, '+<', "$pgdata/$file_corrupted";
seek($file, $pageheader_size, 0);
syswrite($file, '\0\0\0\0\0\0\0\0\0');
close $file;

# Global checksum checks fail
$node->command_checks_all([ 'pg_verify_checksums', '-D', $pgdata],
						  1,
						  [qr/Bad checksums:.*1/],
						  [qr/checksum verification failed/],
						  'fails with corrupted data');

# Checksum checks on single relfilenode fail
$node->command_checks_all([ 'pg_verify_checksums', '-D', $pgdata, '-r',
							$relfilenode_corrupted],
						  1,
						  [qr/Bad checksums:.*1/],
						  [qr/checksum verification failed/],
						  'fails for corrupted data on single relfilenode');

# Utility routine to check that pg_verify_checksums is able to detect
# correctly-named relation files filled with some corrupted data.
sub fail_corrupt
{
	my $node = shift;
	my $file = shift;
	my $pgdata = $node->data_dir;

	# Create the file with some dummy data in it.
	my $file_name = "$pgdata/global/$file";
	append_to_file $file_name, "foo";

	$node->command_checks_all([ 'pg_verify_checksums', '-D', $pgdata],
						  1,
						  [qr/^$/],
						  [qr/could not read block 0 in file.*$file\":/],
						  "fails for corrupted data in $file");

	# Remove file to prevent future lookup errors on conflicts.
	unlink $file_name;
	return;
}

# Authorized relation files filled with corrupted data cause the
# checksum checks to fail.  Make sure to use file names different
# than the previous ones.
fail_corrupt($node, "99990");
fail_corrupt($node, "99990.123");
fail_corrupt($node, "99990_fsm");
fail_corrupt($node, "99990_init");
fail_corrupt($node, "99990_vm");
fail_corrupt($node, "99990_init.123");
fail_corrupt($node, "99990_fsm.123");
fail_corrupt($node, "99990_vm.123");
