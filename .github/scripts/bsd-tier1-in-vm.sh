#!/bin/sh
# Copyright (c) 2026, Oracle and/or its affiliates. All rights reserved.
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
#
# This code is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License version 2 only, as
# published by the Free Software Foundation.  Oracle designates this
# particular file as subject to the "Classpath" exception as provided
# by Oracle in the LICENSE file that accompanied this code.
#
# This code is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# version 2 for more details (a copy is included in the LICENSE file that
# accompanied this code).
#
# You should have received a copy of the GNU General Public License version
# 2 along with this work; if not, write to the Free Software Foundation,
# Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
#
# Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
# or visit www.oracle.com if you need additional information or have any
# questions.

# Runs one tier1 part inside a BSD virtual machine, against the bundles a
# cross build uploaded, from the root of the workspace the VM was handed.
# test-bsd.yml boots the machine; this is what it runs there, the same on
# every BSD but for what each one needs of a JDK it did not build itself.
#
# Usage: bsd-tier1-in-vm.sh <test-suite>
#
# It returns 0 when the tests ran, whatever they found: the VM actions copy
# the workspace back out only when their step succeeds, so a failing exit
# here would throw away the files the failure has to be read from.
# test-bsd.yml reads make's verdict on the runner afterwards.

set -e
suite="$1"
PATH=/usr/pkg/bin:/usr/pkg/sbin:/usr/local/bin:/usr/local/sbin:$PATH
export PATH

JDK="$PWD/bundles/jdk/`ls bundles/jdk`"
TESTS="$PWD/bundles/tests"
JT="$PWD/jtreg/installed"
os=`uname -s`

if [ -f bundles.sha256 ] && command -v sha256sum >/dev/null 2>&1; then
  # A copy the guest damaged fails later in ways that look like JDK bugs --
  # a SIGILL in libjvm, a class file with a bad magic number.  Say so here.
  # The runner serves the bundles; QEMU's user-mode network takes the
  # guest's gateway to the runner's loopback.  That is 10.0.2.2 by QEMU's
  # default, and 192.168.122.2 the way vmactions sets the network up, so
  # ask the routing table.  A file that fails its checksum is fetched from
  # there again, a few times, before giving up.  Where the two copies differ --
  # what the damage looks like -- is the lead on where it comes from.
  gw=`netstat -rn -f inet 2>/dev/null | awk '$1 == "default" { print $2; exit }'`
  server="http://${gw:-10.0.2.2}:8642"
  try=0
  while :; do
    rc=0
    sums=`cd bundles && sha256sum -c ../bundles.sha256 2>&1` || rc=$?
    [ $rc -ne 0 ] || break
    bad=`echo "$sums" | sed -n 's/: FAILED.*$//p'`
    echo "$sums" | grep -v ': OK$' | head -20 | tee -a "$PWD/setup.txt"
    try=`expr $try + 1`
    if [ $try -gt 3 ] || [ -z "$bad" ]; then
      # Files cut short ("Truncated input file") are what a full disk
      # leaves behind; say how full it is and what the workspace takes.
      df -k . /tmp 2>&1 | sed 's/^/  df: /'
      du -sk * .git 2>/dev/null | sort -n | tail -8 | sed 's/^/  du: /'
      echo "the JDK bundle arrived in the guest damaged; not running the tests"
      exit 1
    fi
    for f in $bad; do
      if fetch -q -o "bundles/$f.new" "$server/$f"; then
        n=`cmp -l "bundles/$f" "bundles/$f.new" 2>/dev/null | wc -l`
        echo "$f: `ls -l "bundles/$f" | awk '{print $5}'` bytes here, `ls -l "bundles/$f.new" | awk '{print $5}'` fetched, $n differ; the first (offset, damaged, good, octal):" |
          tee -a "$PWD/setup.txt"
        cmp -l "bundles/$f" "bundles/$f.new" 2>&1 | head -4 | tee -a "$PWD/setup.txt"
        mv "bundles/$f.new" "bundles/$f"
      else
        echo "$f: could not fetch it again from the runner" | tee -a "$PWD/setup.txt"
        # Where the guest's traffic goes, and whether the server answers
        # at all, to see which of the two is missing.
        netstat -rn -f inet 2>/dev/null | grep -E '^(default|0\.0\.0\.0)' | sed 's/^/  route: /'
        if r=`fetch -q -T 10 -o /dev/null "$server/" 2>&1`; then
          echo "  the server's root answers"
        else
          echo "  the server's root does not answer either: $r"
        fi
      fi
    done
    echo "fetched the damaged files again from the runner (try $try)" | tee -a "$PWD/setup.txt"
  done
  echo "bundle checksums match" >> "$PWD/setup.txt"
  df -k . 2>&1 | tail -1 | sed 's/^/df: /' >> "$PWD/setup.txt"
fi

if [ "$os" = NetBSD ]; then
  # A JDK built on NetBSD is marked as it is linked; one cross-built from
  # Linux cannot be, because paxctl(8) only exists here.  Without the mark
  # every launcher dies in VM initialisation, because PaX refuses the
  # writable and executable mapping the JIT asks for.
  find "$JDK" "$TESTS" -type f \( -perm -u+x -o -name '*.so' \) -print |
    while read f; do /usr/sbin/paxctl +m "$f" >/dev/null 2>&1 || :; done

  # The launchers inside the jmods need it too.  jlink assembles a new
  # image out of those, not out of bin/, so marking only the unpacked tree
  # leaves every image a test builds unmarked, and it dies before running a
  # line with "Could not reserve enough space in CodeHeap", which is PaX
  # MPROTECT refusing the JIT's mapping, not a size.
  #
  # A jmod is a zip behind a four-byte header.  Replace only the entries
  # that need marking and pass -D, because the jmod reader rejects
  # directory entries that a plain rezip would add.  Most jmods carry no
  # launcher; those are left alone.
  echo "--- marking the launchers inside the jmods ---"
  WORK="$PWD/jmodwork"
  for m in "$JDK"/jmods/*.jmod; do
    rm -rf "$WORK"; mkdir -p "$WORK"
    dd if="$m" bs=1 count=4 of="$WORK/magic" 2>/dev/null
    dd if="$m" bs=4 skip=1 of="$WORK/body.zip" 2>/dev/null
    ( cd "$WORK" && unzip -q -o body.zip 'bin/*' ) >/dev/null 2>&1 || continue
    [ -d "$WORK/bin" ] || continue
    n=0
    for f in "$WORK"/bin/*; do
      [ -f "$f" ] || continue
      /usr/sbin/paxctl +m "$f" >/dev/null 2>&1 && n=`expr $n + 1`
    done
    [ "$n" -gt 0 ] || continue
    ( cd "$WORK" && zip -q -D -X body.zip bin/* ) || continue
    cat "$WORK/magic" "$WORK/body.zip" > "$m.new" && mv "$m.new" "$m"
    echo "  $n in ${m##*/}"
  done
  rm -rf "$WORK"
fi

if [ "$os" = DragonFly ]; then
  # The image's root is HAMMER2, which keeps a truncated file's last 64K
  # buffer in memory, so a mapping of the part cut off still reads, where
  # every other file system raises SIGBUS.  runtime/Unsafe/InternalErrorTest
  # ("InternalError not thrown") and java/foreign/sharedclosejfr/
  # TestSharedCloseJFR ("InternalError was expected") test for exactly that
  # fault, and tools/javac/6394683/T6394683 stops at "Cannot create files"
  # on the same file system.  The tests work in build/, so put that on
  # tmpfs, which behaves as the tests expect.
  mkdir -p build
  if mount_tmpfs tmpfs build; then
    echo "build/ is on tmpfs" >> "$PWD/setup.txt"
  else
    echo "could not put build/ on tmpfs; the tests run on HAMMER2" | tee -a "$PWD/setup.txt"
  fi
  # tools/javac/6394683/T6394683 rewrites a file once a second for five
  # seconds and still finds its mtime no newer than an older file's
  # ("Cannot create files"), on HAMMER2 and on tmpfs alike.  Record how this
  # machine stamps files and keeps time, to see which of the two is behind.
  {
    sysctl vfs.timestamp_precision 2>&1 || :
    t=build/mtime-probe
    echo a > $t.1; sleep 1; echo b > $t.2; sleep 1; echo c > $t.1
    echo "mtime probe: first `stat -f %m $t.1` second `stat -f %m $t.2` (rewritten after it)"
    # The test makes its newer B.class by opening the existing, empty file
    # with O_TRUNC, as : > does, and writing nothing.
    : > $t.3; m1=`stat -f %m $t.3`; sleep 2; : > $t.3; m2=`stat -f %m $t.3`
    echo "mtime probe: empty file truncated again 2s later: $m1 -> $m2"
    rm -f $t.1 $t.2 $t.3
  } >> "$PWD/setup.txt" 2>&1
fi

if [ "$os" = OpenBSD ]; then
  # The JVM reserves its heap and code cache up front, well past the
  # default data size limit of a login class.  Raising the soft limit to
  # the hard one was not enough: the jdk parts that size the heap from the
  # machine still stopped at
  #   os::commit_memory(0x0000000781000000, 2130706432, 0) failed;
  #   error='ENOMEM' (errno=12)
  # The steps run as root, which may lift the hard limit too.
  ulimit -d unlimited 2>/dev/null || ulimit -Sd `ulimit -Hd`
fi

# Build the smallest image jlink can make and start it.  Eight tier1 tests
# build an image and run it, and anything that stops a jlinked launcher --
# on NetBSD an unmarked one -- fails all eight an hour later as a CodeHeap
# message.  Say so here instead, with what jlink printed.
"$JDK/bin/jlink" --module-path "$JDK/jmods" --add-modules java.base \
    --output "$PWD/probeimage" > "$PWD/jlink.log" 2>&1 || :
if [ -x "$PWD/probeimage/bin/java" ]; then
  if [ "$os" = NetBSD ]; then
    /usr/sbin/paxctl "$PWD/probeimage/bin/java"
    /usr/sbin/paxctl "$PWD/probeimage/bin/java" | grep -q 'mprotect' || {
      echo "a jlink-built image comes out unmarked; the eight image"
      echo "tests will fail in VM initialisation"
      exit 1
    }
  fi
  "$PWD/probeimage/bin/java" -version 2>&1 | head -2
else
  echo "jlink could not build a probe image; it said:"
  sed 's/^/  /' "$PWD/jlink.log" | head -40
  for e in "$PWD"/hs_err_pid*.log; do
    [ -f "$e" ] || continue
    echo "--- $e ---"
    head -30 "$e" | sed 's/^/  /'
  done
  exit 1
fi
rm -rf "$PWD/probeimage"

# What the launcher asks the run-time linker for, so a missing library is
# named here rather than read out of a test log.
echo "--- what the VM sees ---"
uname -a
readelf -d "$JDK/bin/java" 2>/dev/null | grep -E 'RPATH|RUNPATH|NEEDED' ||
  objdump -p "$JDK/bin/java" 2>/dev/null | grep -E 'RPATH|RUNPATH|NEEDED' || :
ldd "$JDK/bin/java" 2>&1 | head -8
echo "--- end ---"

"$JDK/bin/java" -version
# The vector length C2 sizes its code for, read on this machine.  FreeBSD
# runs every thread at the largest length the CPU offers, and under QEMU
# that can be up to 256 bytes, where Linux starts a thread at 64.
"$JDK/bin/java" -XX:+PrintFlagsFinal -version 2>/dev/null |
  grep -E ' (UseSVE|MaxVectorSize|UseSIMDForMemoryOps|UseAVX) ' |
  tee -a "$PWD/setup.txt" || :

# InfoTest's test3 on NetBSD: Process.destroy() leaves "sleep" running,
# though a sleep the probe above spawns dies of SIGTERM.  Do what the test
# does, through the JDK, a few times: start sleep, destroy it, wait, and
# say what the handle saw and whether the process went.
if [ "$os" = NetBSD ]; then
  mkdir -p "$PWD/destroyprobe"
  cat > "$PWD/destroyprobe/DestroyProbe.java" <<'PROBE'
import java.util.concurrent.TimeUnit;
public class DestroyProbe {
    public static void main(String[] args) throws Exception {
        System.out.println("destroy probe: launchMechanism "
                + System.getProperty("jdk.lang.Process.launchMechanism", "(default)"));
        for (int i = 0; i < 20; i++) {
            Process p = new ProcessBuilder("sleep", "60").start();
            ProcessHandle h = p.toHandle();
            java.lang.reflect.Field f = h.getClass().getDeclaredField("startTime");
            f.setAccessible(true);
            long recorded = f.getLong(h);
            String before = recorded + " " + h.info().startInstant()
                    + " now " + ProcessHandle.of(p.pid()).map(x -> {
                        try { return String.valueOf(f.getLong(x)); }
                        catch (Exception e) { return e.toString(); } }).orElse("(gone)");
            long t0 = System.nanoTime();
            p.destroy();
            boolean gone = p.waitFor(15, TimeUnit.SECONDS);
            long ms = (System.nanoTime() - t0) / 1_000_000;
            String after = String.valueOf(ProcessHandle.of(p.pid())
                    .map(x -> x.info().startInstant().toString()).orElse("(gone)"));
            System.out.println("destroy probe: pid " + p.pid() + " start " + before
                    + " -> " + after + ", destroy then wait: " + (gone ? "exited" : "STILL ALIVE")
                    + " after " + ms + " ms");
            if (!gone) {
                boolean sent = ProcessHandle.of(p.pid()).map(ProcessHandle::destroy).orElse(false);
                System.out.println("destroy probe: ProcessHandle.of(pid).destroy() returned " + sent
                        + ", exited within 5s: " + p.waitFor(5, TimeUnit.SECONDS));
                p.destroyForcibly().waitFor();
            }
        }
    }
}
PROBE
  "$JDK/bin/java" --add-opens java.base/java.lang=ALL-UNNAMED \
      "$PWD/destroyprobe/DestroyProbe.java" 2>&1 | tail -45 | tee -a "$PWD/setup.txt" || :
fi

# compiler/loopopts/TestMaxLoopOptsCountReached times out on OpenBSD
# alone, on amd64 under KVM as on aarch64, with C2 still on its one
# compile -- and on amd64 the compiler thread had used only 120 of the
# 480 seconds.  Time the test's own compile here, as the test runs it,
# with malloc as it comes and with junking turned off, and say how the
# time splits between user and system.
if [ "$os" = OpenBSD ] && [ "`uname -m`" = amd64 ]; then
  case "$suite" in *tier1_compiler_3)
    mkdir -p "$PWD/loopprobe"
    "$JDK/bin/javac" -d "$PWD/loopprobe" \
        test/hotspot/jtreg/compiler/loopopts/TestMaxLoopOptsCountReached.java 2>&1 | tail -3 || :
    # The compile spends three quarters of its time in the kernel
    # ("real 31.46 user 6.75 sys 24.15", the same with junking off), so
    # count the system calls it makes, by name.
    ktrace -i -t c -f "$PWD/loopprobe/ktrace.out" "$JDK/bin/java" -Xcomp -XX:-PartialPeelLoop \
        -XX:CompileCommand=quiet -XX:CompileCommand=compileonly,TestMaxLoopOptsCountReached::test \
        -cp "$PWD/loopprobe" TestMaxLoopOptsCountReached > /dev/null 2>&1 || :
    kdump -f "$PWD/loopprobe/ktrace.out" 2>/dev/null |
      awk '$3 == "CALL" { n = $4; sub(/\(.*/, "", n); c[n]++ } END { for (k in c) print c[k], k }' |
      sort -n -r | head -12 | tr '\n' ',' | sed 's/^/loop probe: system calls: /; s/,$/\n/' |
      tee -a "$PWD/setup.txt" || :
    rm -f "$PWD/loopprobe/ktrace.out"
    for m in "" jj; do
      ( MALLOC_OPTIONS=$m; export MALLOC_OPTIONS
        /usr/bin/time -p "$JDK/bin/java" -Xcomp -XX:-PartialPeelLoop -XX:+CITime \
            -XX:CompileCommand=quiet \
            -XX:CompileCommand=compileonly,TestMaxLoopOptsCountReached::test \
            -cp "$PWD/loopprobe" TestMaxLoopOptsCountReached ) > "$PWD/loopprobe/out$m.txt" 2>&1 &
      pid=$!
      ( sleep 300; kill -9 $pid 2>/dev/null ) &
      killer=$!
      wait $pid 2>/dev/null || :
      kill $killer 2>/dev/null || :
      echo "loop probe (MALLOC_OPTIONS=${m:-default}): `grep -E '^(real|user|sys) ' "$PWD/loopprobe/out$m.txt" | tr '\n' ' '`" |
        tee -a "$PWD/setup.txt"
      grep -m1 -E '^ +C2 [{]' "$PWD/loopprobe/out$m.txt" | sed 's/; nmethods.*//; s/^/loop probe:   /' |
        tee -a "$PWD/setup.txt" || :
    done
  ;; esac
fi

# runtime/CompressedOops/CompressedClassPointers fails on FreeBSD/aarch64
# alone: with a 128M heap the class space should land below 4G, for a
# zero narrow klass base, and lands at 0x00000ff000000000 instead.  Log
# every attempt the VM makes to reserve it, and what a process here has
# mapped at its low end, to see what is in the way.
if [ "$os" = FreeBSD ] && [ "`uname -m`" = arm64 ]; then
  case "$suite" in *tier1_runtime)
    "$JDK/bin/java" -XX:+UnlockDiagnosticVMOptions -XX:SharedBaseAddress=8g \
        -Xmx128m -Xshare:off -Xlog:os+map=trace,metaspace+map=debug,gc+metaspace=info \
        -XX:+PrintFlagsFinal -version > "$PWD/ccsprobe.txt" 2>&1 || :
    # os+map at trace says why each attempt below 4G failed ("mmap failed:
    # ... errno=(...)"); the attempts come in the order they were made.
    grep -E 'reserve|mmap failed|Narrow klass base|Compressed class space|Heap address| HeapBaseMinAddress ' \
        "$PWD/ccsprobe.txt" | head -40 | sed 's/^/ccs probe: /' | tee -a "$PWD/setup.txt"
    grep -c 'mmap failed' "$PWD/ccsprobe.txt" | sed 's/^/ccs probe: failed mmaps: /' | tee -a "$PWD/setup.txt"
    sysctl kern.elf64.aslr.enable kern.elf64.aslr.pie_enable vm.max_user_wired \
        2>&1 | sed 's/^/ccs probe: /' | tee -a "$PWD/setup.txt" || :
    # Every attempt below 4G failed with ENOMEM, which mmap returns for an
    # address outside the process's map; ask the kernel where the map
    # starts.
    cat > "$PWD/vmlayout.c" <<'PROBE'
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <stdio.h>
#include <unistd.h>
int main(void) {
  struct kinfo_vm_layout l;
  size_t len = sizeof l;
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_VM_LAYOUT, getpid()};
  if (sysctl(mib, 4, &l, &len, NULL, 0) == -1) { perror("vm_layout"); return 1; }
  printf("min user address 0x%lx, max 0x%lx, text 0x%lx, map flags 0x%x\n",
         (unsigned long)l.kvm_min_user_addr, (unsigned long)l.kvm_max_user_addr,
         (unsigned long)l.kvm_text_addr, l.kvm_map_flags);
  return 0;
}
PROBE
    if cc -o "$PWD/vmlayout" "$PWD/vmlayout.c" > "$PWD/vmlayout.log" 2>&1; then
      "$PWD/vmlayout" 2>&1 | sed 's/^/ccs probe: /' | tee -a "$PWD/setup.txt"
    else
      tail -3 "$PWD/vmlayout.log" | sed 's/^/ccs probe: vmlayout did not build: /' | tee -a "$PWD/setup.txt"
    fi
    # The map starts at 0x1000, so the ENOMEMs mean the ranges are taken:
    # MAP_FIXED | MAP_EXCL fails that way over an existing mapping.  List
    # what a JVM with the test's flags has below 4G, while it runs.
    mkdir -p "$PWD/ccsprobe"
    printf 'public class Nap { public static void main(String[] a) throws Exception { Thread.sleep(600000); } }\n' \
      > "$PWD/ccsprobe/Nap.java"
    "$JDK/bin/javac" -d "$PWD/ccsprobe" "$PWD/ccsprobe/Nap.java" 2>&1 | tail -3 || :
    "$JDK/bin/java" -XX:+UnlockDiagnosticVMOptions -XX:SharedBaseAddress=8g -Xmx128m \
        -Xshare:off -cp "$PWD/ccsprobe" Nap &
    nap=$!
    sleep 20
    procstat -v $nap 2>/dev/null |
      awk 'NR == 1 || length($2) <= 10 || $2 < "0x0000000100000000"' | head -40 |
      sed 's/^/ccs probe: /' | tee -a "$PWD/setup.txt" || :
    kill $nap 2>/dev/null || :
    wait $nap 2>/dev/null || :
  ;; esac
fi

# compiler/loopopts/TestMaxLoopOptsCountReached runs in 100 seconds on the
# NetBSD/aarch64 guest, and times out on the OpenBSD one with C2 still on
# its one -Xcomp compile after 1448 seconds of CPU; OpenBSD alone takes
# its CPU for one that wants UseSIMDForMemoryOps.  Time the same fixed C2
# work on each guest, with that flag as found and turned off, to see
# whether the guest or the flag is behind it.  Only in the shard that
# holds the test, to keep the others' time.
case "`uname -m`" in
  aarch64|arm64|evbarm)
    case "$suite:${SHARD:-1}" in *tier1_compiler_3:3)
      sysctl hw.model 2>/dev/null | tee -a "$PWD/setup.txt" || :
      "$JDK/bin/java" -Xlog:os+cpu -version 2>&1 | grep -E '^\[.*\]\[os,cpu' | head -3 |
        tee -a "$PWD/setup.txt" || :
      for f in -XX:+UseSIMDForMemoryOps -XX:-UseSIMDForMemoryOps; do
        s=`date +%s`
        "$JDK/bin/java" $f -XX:-TieredCompilation -Xcomp \
            -XX:CompileOnly=java.lang.String::* -XX:+CITime -version \
            > "$PWD/c2probe.txt" 2>&1 || :
        e=`date +%s`
        echo "C2 probe $f: `expr $e - $s` s wall; `grep -m1 -E '^ +C2 [{]' "$PWD/c2probe.txt" | sed 's/; nmethods.*//'`" |
          tee -a "$PWD/setup.txt"
      done ;;
    esac ;;
esac

# What this kernel sends for a read past the end of a mapped file that was
# truncated under it.  HotSpot turns that fault, in an unsafe access, into
# an InternalError (runtime/Unsafe/InternalErrorTest), and takes it to be
# SIGBUS as on Linux; DragonFly and NetBSD/aarch64 fail that test without
# a crash.  The base system's cc builds the probe where there is one.
if command -v cc >/dev/null 2>&1; then
  cat > "$PWD/mapprobe.c" <<'PROBE'
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
static sigjmp_buf env;
static volatile int got_sig, got_code;
static void h(int sig, siginfo_t *si, void *uc) {
  (void)uc; got_sig = sig; got_code = si->si_code; siglongjmp(env, 1);
}
int main(void) {
  long pg = sysconf(_SC_PAGESIZE);
  char path[] = "/tmp/mapprobeXXXXXX";
  int fd = mkstemp(path);
  if (fd < 0 || ftruncate(fd, 2 * pg) != 0) { perror("setup"); return 1; }
  volatile char *p = mmap(NULL, 2 * pg, PROT_READ, MAP_SHARED, fd, 0);
  if (p == MAP_FAILED) { perror("mmap"); return 1; }
  if (ftruncate(fd, pg) != 0) { perror("truncate"); return 1; }
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = h;
  sa.sa_flags = SA_SIGINFO;
  sigaction(SIGBUS, &sa, NULL);
  sigaction(SIGSEGV, &sa, NULL);
  if (sigsetjmp(env, 1) == 0) {
    char c = p[pg + 8];
    printf("read past EOF of a mapped file: no fault, read %d\n", c);
  } else {
    printf("read past EOF of a mapped file: %s si_code=%d (SEGV_MAPERR=%d SEGV_ACCERR=%d BUS_ADRERR=%d BUS_OBJERR=%d)\n",
           got_sig == SIGBUS ? "SIGBUS" : got_sig == SIGSEGV ? "SIGSEGV" : "other",
           got_code, SEGV_MAPERR, SEGV_ACCERR, BUS_ADRERR, BUS_OBJERR);
  }
  unlink(path);
  return 0;
}
PROBE
  if cc -o "$PWD/mapprobe" "$PWD/mapprobe.c" >/dev/null 2>&1; then
    "$PWD/mapprobe" 2>&1 | tee -a "$PWD/setup.txt" || :
  fi
fi

# java/lang/ProcessHandle/InfoTest fails on NetBSD/amd64 with "timeout
# waiting for process to terminate" after Process.destroy(), and prints the
# child's start time as a day or so after 1970.  ProcessHandle signals a
# pid only while the start time it reads from kinfo_proc2 still matches
# the one it read first, so a start time that moves would leave the child
# alive.  Read a child's the way the JDK does, a few times over three
# seconds, next to the clock and the boot time.
if [ "$os" = NetBSD ] && command -v cc >/dev/null 2>&1; then
  cat > "$PWD/startprobe.c" <<'PROBE'
#include <sys/param.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <unistd.h>
extern char **environ;
static void show(const char *how, pid_t pid, long long bt) {
  struct kinfo_proc2 kp; size_t len = sizeof kp;
  int mib[6] = {CTL_KERN, KERN_PROC2, KERN_PROC_PID, pid, sizeof kp, 1};
  struct timeval now; gettimeofday(&now, NULL);
  if (sysctl(mib, 6, &kp, &len, NULL, 0) == -1) { perror("sysctl"); return; }
  printf("start time probe (%s): stat %d uvalid %d start %llu.%06llu (ms %lld) now %lld.%06ld boottime %lld\n",
         how, (int)kp.p_stat, (int)kp.p_uvalid, (unsigned long long)kp.p_ustart_sec,
         (unsigned long long)kp.p_ustart_usec,
         (long long)kp.p_ustart_sec * 1000 + kp.p_ustart_usec / 1000,
         (long long)now.tv_sec, (long)now.tv_usec, bt);
}
int main(void) {
  struct timeval bt; size_t btl = sizeof bt;
  int bmib[2] = {CTL_KERN, KERN_BOOTTIME};
  sysctl(bmib, 2, &bt, &btl, NULL, 0);
  pid_t pid = fork();
  if (pid == 0) { execl("/bin/sleep", "sleep", "10", (char *)NULL); _exit(1); }
  for (int i = 0; i < 3; i++) { show("fork", pid, bt.tv_sec); sleep(1); }
  kill(pid, SIGKILL);
  /* The JDK starts children with posix_spawn, which NetBSD does in the
     kernel; read the child the moment the call returns, as ProcessImpl
     does when it makes the child's handle, and again later. */
  char *argv[] = {"sleep", "10", NULL};
  if (posix_spawn(&pid, "/bin/sleep", NULL, NULL, argv, environ) != 0) {
    perror("posix_spawn"); return 0;
  }
  show("posix_spawn, at once", pid, bt.tv_sec);
  show("posix_spawn, at once", pid, bt.tv_sec);
  usleep(200000);
  show("posix_spawn, 0.2s", pid, bt.tv_sec);
  sleep(1);
  show("posix_spawn, 1.2s", pid, bt.tv_sec);
  if (kill(pid, SIGTERM) == 0) {
    int st; waitpid(pid, &st, 0);
    printf("start time probe: SIGTERM to the spawned child: %s\n",
           WIFSIGNALED(st) ? "it died" : "it lived");
  }
  /* The JDK reads the start time once jspawnhelper has said it is alive,
     and jspawnhelper then execs the program; read it before and after
     an exec in the same process. */
  char *argv2[] = {"sh", "-c", "sleep 1; exec /bin/sleep 5", NULL};
  if (posix_spawn(&pid, "/bin/sh", NULL, NULL, argv2, environ) != 0) {
    perror("posix_spawn"); return 0;
  }
  usleep(300000);
  show("before exec", pid, bt.tv_sec);
  sleep(2);
  show("after exec", pid, bt.tv_sec);
  kill(pid, SIGKILL);
  return 0;
}
PROBE
  if cc -o "$PWD/startprobe" "$PWD/startprobe.c" >"$PWD/startprobe.log" 2>&1; then
    "$PWD/startprobe" 2>&1 | tee -a "$PWD/setup.txt" || :
  else
    { echo "start time probe did not build:"; tail -5 "$PWD/startprobe.log"; } | tee -a "$PWD/setup.txt"
  fi
fi

# A cross build leaves out the default CDS archive -- jdk-options.m4 turns
# --enable-cds-archive off for cross compilation, since the build cannot run
# what it built -- and a JDK built on the BSD itself would carry one.  Dump
# it here, as Images.gmk would have, so the tests that assume lib/server/
# classes.jsa (NonJVMVariantLocation and TestCDSVMCrash start with
# -Xshare:on) test the JDK a native build makes.  The VM has to be what
# dumps it: the archive records the running JVM.
"$JDK/bin/java" -Xshare:dump -XX:SharedArchiveFile="$JDK/lib/server/classes.jsa" \
    -Xmx128M -Xms128M > "$PWD/cds-dump.log" 2>&1 ||
  { echo "the default CDS archive could not be dumped:"; tail -20 "$PWD/cds-dump.log"; }

# The makefiles are written for GNU sed and grep; where the base system's
# are the BSD ones, the packaged GNU ones are named instead.
gnu=""
if command -v gsed >/dev/null 2>&1; then gnu="$gnu SED=`command -v gsed`"; fi
if command -v ggrep >/dev/null 2>&1; then gnu="$gnu GREP=`command -v ggrep`"; fi

# A part split across SHARDS jobs runs every SHARDS-th test file of it,
# starting at the SHARD-th, and leaves the rest to the other jobs by listing
# them as problems.  jtreg -l names the tests the part selects, after the
# keywords and @requires, so the split is of what would really run.
extra=""
monitor=""
if [ "${SHARDS:-1}" -gt 1 ]; then
  root=${suite%%:*}
  "$JDK/bin/java" -jar "$JT/lib/jtreg.jar" -l -jdk:"$JDK" -k:'!headful' \
      "$PWD/${root%/}:${suite#*:}" > "$PWD/shard-all.txt" 2>&1 || :
  grep -E '\.(java|sh|html)(#.*)?$' "$PWD/shard-all.txt" |
    sort -u > "$PWD/shard-tests.txt"
  sed 's/#.*//' "$PWD/shard-tests.txt" | sort -u > "$PWD/shard-files.txt"
  n=`wc -l < "$PWD/shard-files.txt"`
  if [ "$n" -gt 0 ]; then
    # Split by file, so the variants of one test stay together, but list
    # every variant to exclude by its own name: an entry for Foo.java does
    # not exclude Foo.java#id, and the variants ran in every shard.
    awk -v k="$SHARD" -v n="$SHARDS" '
        NR == FNR { mine[$0] = ((FNR - 1) % n == k - 1); next }
        { f = $0; sub(/#.*/, "", f); if (!mine[f]) print $0 " 0000000 generic-all" }' \
        "$PWD/shard-files.txt" "$PWD/shard-tests.txt" > "$PWD/shard-exclude.txt"
    m=`sed 's/#.*//' "$PWD/shard-exclude.txt" | sort -u | wc -l`
    echo "shard $SHARD of $SHARDS: `expr $n - $m` of $n test files" | tee -a "$PWD/setup.txt"
    extra=";EXTRA_PROBLEM_LISTS=$PWD/shard-exclude.txt"
  else
    { echo "could not list the tests of $suite, so running all of them; jtreg said:"
      tail -5 "$PWD/shard-all.txt"; } | tee -a "$PWD/setup.txt"
  fi
fi

if [ "$os" = DragonFly ]; then
  # jdk/tier1 part 1 takes the whole VM down: ssh stops answering about
  # three minutes after java/lang/ProcessHandle/InfoTest passes, every time,
  # and nothing comes back to say which test was running.  One test at a
  # time, so the last name in the log is the one that does it.
  case "$suite" in *tier1_part1) extra="$extra;JOBS=1" ;; esac
  # Twice now the machine has gone just after InfoTest passed, as jtreg
  # moved on to java/lang/ProcessHandle/OnExitTest, which builds trees of
  # processes, kills them and waits for each.  Say every half minute how
  # many processes there are and how much memory is free, so the last
  # lines before the silence show whether something ran out.
  case "$suite" in *tier1_part1)
    ( while sleep 30; do
        n=`ps ax 2>/dev/null | wc -l` || :
        f=`sysctl -n vm.stats.vm.v_free_count 2>/dev/null` || :
        j=`ps ax -o comm 2>/dev/null | grep -c '^java'` || :
        echo "monitor: `date +%H:%M:%S` processes $n, java $j, free pages $f"
        ps ax -o pid,ppid,rss,etime,command 2>/dev/null | sort -k3 -n -r | sed -n '2,3p' | cut -c1-140 | sed 's/^/monitor:   /' || :
      done ) &
    monitor=$!
  ;; esac
fi

gmake test-prebuilt $gnu \
  TEST="$suite" \
  BOOT_JDK="$JDK" \
  JT_HOME="$JT" \
  JDK_IMAGE_DIR="$JDK" \
  TEST_IMAGE_DIR="$TESTS" \
  JTREG="JAVA_OPTIONS=-XX:-CreateCoredumpOnCrash;VERBOSE=fail,error,time;KEYWORDS=!headful;TIMEOUT_FACTOR=${TIMEOUT_FACTOR:-4}$extra"

[ -z "$monitor" ] || kill $monitor 2>/dev/null || :

# make test-prebuilt prints "TEST FAILURE" and then returns 0: it reports
# the failure as build/run-test-prebuilt/make-support/exit-with-error.
# Name what failed here, where the log is read; the verdict is passed on
# the runner.
R=build/run-test-prebuilt
if [ -f $R/make-support/exit-with-error ]; then
  echo "--- tests that failed ---"
  cat $R/test-results/*/text/newfailures.txt 2>/dev/null || :
  echo "--- tests that errored ---"
  cat $R/test-results/*/text/other_errors.txt 2>/dev/null || :
  # Why each one failed, at the very end of the log: the log is read from
  # its tail, and a part's own output runs to more lines than can be
  # fetched, so the reason would otherwise be out of reach.
  cat $R/test-results/*/text/newfailures.txt \
      $R/test-results/*/text/other_errors.txt 2>/dev/null |
    grep -v '^#' | sed 's/[[:space:]].*//' | sort -u | head -40 |
    while read t; do
      [ -n "$t" ] || continue
      # A test with several @test blocks is named Foo.java#id, and jtreg
      # writes each variant to Foo_id.jtr; matching on Foo alone picks up
      # whichever variant find meets first, often not the one that failed.
      f=${t%%#*}
      case "$t" in *#*) f="${f%.*}_${t#*#}" ;; *) f="${f%.*}" ;; esac
      jtr=`find $R/test-support -path "*/$f.jtr" 2>/dev/null | head -1`
      [ -n "$jtr" ] || continue
      echo "--- $t ---"
      grep -E 'Exception|Error|FAILED|failed|expected|timed out|^TEST RESULT' "$jtr" |
        grep -v '^[[:space:]]*at ' | head -15
      # A VM that exits without a word ("Unexpected exit from test [exit
      # code: 1]") leaves nothing for the pattern above; its own output is
      # then the only lead.  An OutputAnalyzer check that misses its line
      # prints the child's whole stdout and stderr here just before the
      # exception, so take enough lines to reach them.
      sed -n '/^----------System.err/,/^----------rerun/p' "$jtr" |
        grep -v '^[[:space:]]*at ' | tail -45
    done
  # A crash names only its problematic frame on the console; what faulted
  # and where is in the hs_err file, which otherwise has to be fetched from
  # the artifact.  A gtest crash leaves nothing else to go on.
  find $R/test-support -name 'hs_err_pid*.log' 2>/dev/null | head -4 |
    while read e; do
      echo "--- ${e#$R/test-support/} ---"
      grep -m1 -A1 '^siginfo:' "$e"
      sed -n '/^Registers:/,/^$/p' "$e" | head -24
      sed -n '/^Native frames:/,/^$/p' "$e" | head -16
    done
  echo "--- end ---"
fi
# What the start of the log said about the machine and the split, again at
# the end: only the last 5000 lines of a job's log can be fetched, and a
# long part pushes the start out of reach.
echo "--- setup ---"
uname -srm
cat "$PWD/setup.txt" 2>/dev/null || :
echo "--- end ---"
exit 0
