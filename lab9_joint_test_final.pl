#!/usr/bin/perl
# ============================================================
# lab9_joint_test.pl  (Lab 9 — Lab 8 fifo_top, 5 SW regs)
#
# Register map (Lab 8 original, NUM_SOFTWARE_REGS=5):
#   0x2000100  CMD         SW0
#   0x2000104  PROC_ADDR   SW1
#   0x2000108  WDATA_HI    SW2
#   0x200010C  WDATA_LO    SW3
#   0x2000110  WDATA_CTRL  SW4
#   0x2000114  STATUS      HW0
#   0x2000118  RDATA_HI    HW1
#   0x200011C  RDATA_LO    HW2
#   0x2000120  RDATA_CTRL  HW3
#   0x2000124  POINTERS    HW4
#
# CMD bits:
#   [1:0] = mode  (00=IDLE, 01=PROC, 10=FIFO_OUT, 11=FIFO_IN)
#   [2]   = reset
#   [3]   = ARM_start
#   [5]   = GPU2_start  (bit 5 = 0x20)
# ============================================================

use strict;
use warnings;

my $CMD_REG        = 0x2000100;
my $PROC_ADDR_REG  = 0x2000104;
my $WDATA_HI_REG   = 0x2000108;
my $WDATA_LO_REG   = 0x200010C;
my $WDATA_CTRL_REG = 0x2000110;
my $STATUS_REG     = 0x2000114;
my $RDATA_HI_REG   = 0x2000118;
my $RDATA_LO_REG   = 0x200011C;
my $RDATA_CTRL_REG = 0x2000120;
my $PSTATUS_REG    = 0x2000124;

my $ST_ARM_DONE  = 0x01;
my $ST_GPU2_DONE = 0x04;  # PROC_STATUS[2] = gpu_done
my $TIMEOUT      = 2000;

my ($pass, $fail) = (0, 0);

sub regwrite {
    my ($addr, $val) = @_;
    system(sprintf("regwrite 0x%08x 0x%08x", $addr, $val));
}

sub regread_val {
    my $out = `regread 0x@{[sprintf("%08x", $_[0])]}`;
    my ($v) = $out =~ /:\s*(0x[0-9a-fA-F]+)/i;
    $v = '0' unless defined $v;
    return hex($v);
}

my $write_toggle = 0;

sub write_bram {
    my ($addr, $hi, $lo) = @_;
    $write_toggle ^= 0x100;
    regwrite($PROC_ADDR_REG,  $addr);
    regwrite($WDATA_HI_REG,   $hi);
    regwrite($WDATA_LO_REG,   $lo);
    regwrite($WDATA_CTRL_REG, $write_toggle);
}

sub read_bram {
    my ($addr) = @_;
    regwrite($PROC_ADDR_REG, $addr);
    my $hi = regread_val($RDATA_HI_REG);
    my $lo = regread_val($RDATA_LO_REG);
    return ($hi, $lo);
}

sub check {
    my ($label, $got_hi, $got_lo, $exp_hi, $exp_lo) = @_;
    if ($got_hi == $exp_hi && $got_lo == $exp_lo) {
        printf("  PASS  %s\n", $label);
        $pass++;
    } else {
        printf("  FAIL  %s\n        expected %08x_%08x\n        got      %08x_%08x\n",
               $label, $exp_hi, $exp_lo, $got_hi, $got_lo);
        $fail++;
    }
}

sub poll_done {
    my ($bit, $label) = @_;
    for my $i (1..$TIMEOUT) {
        my $st = regread_val($PSTATUS_REG);
        return 1 if ($st & $bit);
        select(undef, undef, undef, 0.01);
    }
    print "  TIMEOUT: $label\n";
    $fail++;
    return 0;
}

print "\n================================================================\n";
print "  Lab 9 Joint Test: ARM + GPU2 pipeline\n";
print "================================================================\n\n";

# -------------------------------------------------------
print "[1] Reset\n";
regwrite($CMD_REG, 0x04);   # reset=1
regwrite($CMD_REG, 0x00);   # reset=0

# -------------------------------------------------------
print "[2] Writing test packet into FIFO BRAM\n";
regwrite($CMD_REG, 0x01);   # PROC mode

# Header words at BRAM[6,7] — arm_cpu_wrapper processes BRAM[6..12]
write_bram(6, 0x00000001, 0x00000002);   # word 6: hi=1, lo=2
write_bram(7, 0x00000003, 0x00000004);   # word 7: hi=3, lo=4

# BF16 data words at BRAM[0,1,2] — GPU LD64 reads byte addr 0,8,16
write_bram(0, 0x40004000, 0x40004000);   # Vec A: 2.0 packed
write_bram(1, 0x3fc03fc0, 0x3fc03fc0);   # Vec B: 1.5 packed
write_bram(2, 0x3f003f00, 0x3f003f00);   # Vec C: 0.5 packed

print "    done\n\n";

# -------------------------------------------------------
print "[3] Starting ARM (PROC mode + ARM_start)\n";
regwrite($CMD_REG, 0x01 | 0x08);   # PROC + ARM_start (edge)
regwrite($CMD_REG, 0x01);           # clear ARM_start
sleep(2);                           # wait for ARM to finish (poll unreliable)

# -------------------------------------------------------
print "\n[4] Verify ARM result\n";
regwrite($CMD_REG, 0x01);   # PROC mode, no rdata_sel needed

my ($h0, $l0) = read_bram(6);
check("Header word 0 (+1)", $h0, $l0, 0x00000002, 0x00000003);

my ($h1, $l1) = read_bram(7);
check("Header word 1 (+1)", $h1, $l1, 0x00000004, 0x00000005);

# -------------------------------------------------------
print "\n[5] Loading BF16 vectors into GPU2 via BRAM (words 2,3,4)\n";
# Already written above — verify readback
my ($va_hi, $va_lo) = read_bram(0);
check("GPU2 Vec A readback", $va_hi, $va_lo, 0x40004000, 0x40004000);

my ($vb_hi, $vb_lo) = read_bram(1);
check("GPU2 Vec B readback", $vb_hi, $vb_lo, 0x3fc03fc0, 0x3fc03fc0);

my ($vc_hi, $vc_lo) = read_bram(2);
check("GPU2 Vec C readback", $vc_hi, $vc_lo, 0x3f003f00, 0x3f003f00);

# -------------------------------------------------------
print "\n[6] Starting GPU2 (BF_MAC: 2.0*1.5+0.5 = 3.5)\n";
regwrite($CMD_REG, 0x01 | 0x10);   # PROC + GPU2_start (bit 5)
regwrite($CMD_REG, 0x01);           # clear GPU2_start

if (poll_done($ST_GPU2_DONE, "gpu2_done")) {
    my ($rhi, $rlo) = read_bram(0);  # GPU writes result to BRAM word 0
    check("GPU2 BF_MAC result (3.5)", $rhi, $rlo, 0x40604060, 0x40604060);
}

# -------------------------------------------------------
print "\n================================================================\n";
printf("  PASS: %d   FAIL: %d\n", $pass, $fail);
print "================================================================\n";
print $fail ? "  FAILURES — check register values above\n" : "  ALL PASS\n";
print "\n";
