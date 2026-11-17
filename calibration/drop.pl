#!/usr/bin/perl
# Simulation helper: write copies of a translation with one sentence removed.
# usage: drop.pl TRANSLATION.txt OUTDIR  -> OUTDIR/drop-PP-SS.txt (paragraph, sentence), prints the list
use strict; use warnings; no warnings 'utf8';
my ($f, $dir) = @ARGV;
open my $h, '<:encoding(UTF-8)', $f or die; local $/; my $t = <$h>; close $h;
my $SENT = qr/(?:[.!?\x{2026}]+|[\x{061F}\x{06D4}\x{0589}\x{0964}\x{1362}])["'\x{201D}\x{2019}\x{00BB}\)\]]*(?:[ \t]+|(?=\n)|\z)|[\x{3002}\x{FF01}\x{FF1F}]+["\x{201D}\x{300D}]*/;
my @paras = split /(\n[ \t]*\n\s*)/, $t;   # keeps separators at odd indexes
my $pn = 0;
for (my $i = 0; $i < @paras; $i += 2) {
  $pn++;
  my $p = $paras[$i]; my @sent; my $pos = 0;
  while ($p =~ /$SENT/g) { push @sent, [$pos, pos($p)]; $pos = pos($p) }
  push @sent, [$pos, length $p] if $pos < length($p) && substr($p, $pos) =~ /\S/;
  next if @sent < 2;                        # never empty a whole paragraph
  for my $k (0 .. $#sent) {
    my $q = substr($p, 0, $sent[$k][0]) . substr($p, $sent[$k][1]);
    $q =~ s/[ \t]+$//;
    my @copy = @paras; $copy[$i] = $q;
    my $name = sprintf('%s/drop-%02d-%02d.txt', $dir, $pn, $k + 1);
    open my $o, '>:encoding(UTF-8)', $name or die; print $o join('', @copy); close $o;
    printf "%s\t%d\t%d\t%d\t%d\n", $name, $pn, $k + 1, scalar(@sent), $sent[$k][1] - $sent[$k][0];
  }
}
