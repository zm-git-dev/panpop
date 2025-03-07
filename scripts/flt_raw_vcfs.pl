#!/usr/bin/env perl
#===============================================================================
#
#         FILE: 04-05.MISS_SNP_ALL.pl
#
#        USAGE: ./04-05.MISS_SNP_ALL.pl
#
#  DESCRIPTION:  !!! By group !!! Muti-CPU !!!
#			删除丢失10%以上的; 删除深度异常位点比例超过10%的位点信息; 
#			req; INDEL; 'PASS'; QUAL<20; 过滤len(REF|ALT)>1
#
#      OPTIONS: ---
# REQUIREMENTS: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Zeyu Zheng (Lanzhou University), zhengzy21@lzu.edu.cn
# ORGANIZATION:
#      VERSION: 1.0
#      CREATED: 1/24/2022 07:23:37 PM
#     REVISION: ---
#===============================================================================


use strict;
use warnings;
use utf8;
use Getopt::Long;
use v5.10;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use zzIO;
use MCE::Flow;
use MCE::Candy;


my $depth_file;

##### miss_threshold:
### >1:  no filter
### 1:  only filter all missing site
### 0:  only keep none missing site
### 0~1:  filter
my $miss_threshold=1; 

my($in_vcf, $opt_help);
my $thread='auto';
my $out_file = '-';

my $dp_min_fold = 0.33;
my $dp_max_fold = 3;
my $mad_min_fold = 0.11;
my $min_GQ = 0;
my $remove_fail = 0;

my $vcf_header_append = "##flt $0 @ARGV";

GetOptions (
    'help|h!' => \$opt_help,
    'i|invcf=s' => \$in_vcf,
    'p|threads=i' => \$thread,
    'G|depth_file=s' => \$depth_file,
    'miss_threshold=s' => \$miss_threshold,
    'o|outvcf=s' => \$out_file,
    'dp_min_fold=s' => \$dp_min_fold,
    'dp_max_fold=s' => \$dp_max_fold,
    'mad_min_fold=s' => \$mad_min_fold,
    'min_GQ=i' => \$min_GQ,
    'remove_fail!' => \$remove_fail,
);


sub usage {
    print <<EOF;
Usage: $0 [options]
Options:
    -i | --invcf	    input vcf file
    -o | --outvcf	    output file, default: -
    -p | --threads  	thread number, default: auto
    -G|depth_file	    Mean depth for each sample
    --dp_min_fold		Hard-filter DP in each sample and each site, default: 0.33
    --dp_max_fold		Hard-filter DP in each sample and each site, default: 3
    --mad_min_fold		Hard-filter MAD (Minimum site allele depth) in each sample and each site, default: 0.11
    --miss_threshold	Filter site with more than X missing rates. Range from 0 to 1.	default: 1 (not filter)
    --min_GQ			Hard-filter GQ in each sample and each site, default: 0
    --remove_fail       Bool. Whether to remove fail variants. default: false.
EOF
    exit;
}

&usage() if ($opt_help || ! $in_vcf );

my $O = open_out_fh($out_file, 8);


print STDERR "\n** Now in node: ";
print STDERR`hostname`;


foreach ($in_vcf, $depth_file) {
    next if $_ eq '-';
    die "file not exist: $_\n" unless -e $_;
}


my %dp=&readdp($depth_file);
#print STDERR "GC: ".join(' ',sort keys %dp)."\n";


my $INVCF = open_in_fh($in_vcf);
my @idline;
print STDERR "Processing snp_vcf: $in_vcf\n";
while ( <$INVCF> ){
    if ( /^##/ ){
        print $O $_;
        next;
    }
    if (/^#/){
        print $O join($vcf_header_append);
        chomp;
        print STDERR $_."\n";
        if (/^#CHROM\s+POS\s+ID\s+REF\s+ALT\s+QUAL\s+FILTER\s+INFO\s+FORMAT\s+\w+/){
            @idline=split(/\s+/,$_);
            print $O join("\t",@idline)."\n";
            last;
        }else{
            print STDERR $_;
            last;
        }
    }
}
die "NO idline: \n" if ! @idline;
my $miss_threshold_now=($#idline-8) * $miss_threshold; ## 删除丢失 ?% 以上的
$miss_threshold_now=int($miss_threshold_now)+1 if $miss_threshold_now>int($miss_threshold_now) + 0.5;

say STDERR "All ids: " . (scalar($#idline)-8);
say STDERR "Max missing ids: $miss_threshold_now";

if ($thread eq 1) {
    while(<$INVCF>) {
        my $result = &flt($_);
        say $O $result if defined $result;
    }
    exit();
}

sub flt_mce {
    my ( $mce, $chunk_ref, $chunk_id ) = @_;
    my $result = &flt($$chunk_ref[0]);
    if (defined $result) {
        $mce->gather($chunk_id, $result, "\n") 
    } else {
        $mce->gather($chunk_id);
    }
}

mce_flow_f {
    chunk_size => 1,
    max_workers => $thread,  
    gather => MCE::Candy::out_iter_fh($O)
    },
    \&flt_mce,
    $INVCF;

close $INVCF;

print STDERR "tabix -p vcf $out_file\n";

THEEND:

print STDERR "\n** ALL Done\n";
print STDERR `date`;

exit 0;



sub readdp {
    my ($in) = @_;
    my %r;
    my $D = open_in_fh($in);
    while (<$D>) {
        chomp;
        next unless $_;
        next if /^#/;
        my @a=split(/\s+/,$_);
        $r{$a[0]}=$a[1];
    }
    close $D;
    return %r;
}




sub flt {
    my $line=$_;
    chomp $line;
    return undef unless $line;
    my @a=split(/\s+/,$line);
    return undef if /^#/;
    ##  VCF:
    ##   0    1   2  3    4   5      6     7    8      9...
    ## CHROM POS ID REF  ALT QUAL FILTER INFO FORMAT   ...
    # my $site_info = &get_info($a[7]);
    my @alts = ($a[3], split(',',$a[4]));
    my $all=0;
    my $alt=0;
    my $DP_num;
    my $GQ_num;
    my $MAD_num;
    my @info=split(/:/,$a[8]);
    for (my $ii=0;$ii<@info;$ii++){
        if ($info[$ii] eq 'DP'){
            $DP_num = $ii ;
            next;
        } elsif($info[$ii] eq 'GQ'){
            $GQ_num = $ii;
            next;
        } elsif($info[$ii] eq 'MAD'){
            $MAD_num = $ii;
            next;
        }
    }
    #say STDERR "no DP_num" unless defined $DP_num;
    my $miss=0;
    for (my $i=9;$i<@a;$i++){
        my $id=$idline[$i];
        my $iddp_avg=$dp{$id} // die "dp not in list: $id";
        my $mindp = $iddp_avg * $dp_min_fold;
        my $maxdp = $iddp_avg * $dp_max_fold;
        my $minMAD = $iddp_avg * $mad_min_fold;
        $minMAD = 1 if $minMAD < 1;
        if ($a[$i]=~m#^\.[|/]\.#){
            $miss++;
            next;
        } elsif ( $a[$i] =~ m#^(\d+)[|/](\d+)# ) {
            $alt = $alt + $1 + $2;
            $all = $all + 2;
            next unless defined $DP_num;
            my @idinfo=split(/:/,$a[$i]);
            my $iddp=$idinfo[$DP_num] // die "no iddp found: $line";
            $iddp=0 if $iddp eq '.';
            if ( $iddp < $mindp || $iddp > $maxdp || 
                ($min_GQ > 0 and defined $GQ_num and exists $idinfo[$GQ_num] and 
                   $idinfo[$GQ_num] ne '.' and $idinfo[$GQ_num] < $min_GQ) ||
                ($minMAD > 0 and defined $MAD_num and exists $idinfo[$MAD_num] and 
                   $idinfo[$MAD_num] ne '.' and $idinfo[$MAD_num]< $minMAD ) 
                ) {
                $miss++;
                $idinfo[0] = './.';
                $a[$i] = join(':',@idinfo);
                next;
            }
        } else{
            die "Error sample alle: $a[0] $a[1] $a[$i]";
        }
    }
    #say "$miss $miss_threshold_now";
    my $is_pass=1;
    if ( $miss >= $miss_threshold_now ) {
        $a[6]="MISS";
        $is_pass=0;
    }
    if ($remove_fail==1 and $is_pass==0) {
        return(undef);
    }
    $a[6]='PASS' if $is_pass==1;
    return join("\t",@a);
}


sub get_info {
    my $in = $_[0];
    my %ret;
    my @a = split ';',$in;
    foreach my $a (@a) {
        my @b = split '=',$a;
        $ret{$b[0]} = defined $b[1] ? $b[1] : 0;
    }
    return \%ret;
}



