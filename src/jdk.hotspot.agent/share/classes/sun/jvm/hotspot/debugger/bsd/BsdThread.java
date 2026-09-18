/*
 * Copyright (c) 2002, 2022, Oracle and/or its affiliates. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 *
 */

package sun.jvm.hotspot.debugger.bsd;

import sun.jvm.hotspot.debugger.*;

class BsdThread implements ThreadProxy {
    private BsdDebugger debugger;
    private int         thread_id;
    private long        unique_thread_id;

    /** The address argument must be the address of the _thread_id in the
        OSThread. It's value is result ::gettid() call. */
    BsdThread(BsdDebugger debugger, Address threadIdAddr, Address uniqueThreadIdAddr) {
        this.debugger = debugger;
        // FIXME: size of data fetched here should be configurable.
        // However, making it so would produce a dependency on the "types"
        // package from the debugger package, which is not desired.
        this.thread_id = (int) threadIdAddr.getCIntegerAt(0, 4, true);
        this.unique_thread_id = uniqueThreadIdAddr.getCIntegerAt(0, 8, true);
    }

    BsdThread(BsdDebugger debugger, long id) {
        this.debugger = debugger;
        // use unique_thread_id to identify thread
        this.unique_thread_id = id;
    }

    public boolean equals(Object obj) {
        if (!(obj instanceof BsdThread other)) {
            return false;
        }

        return (other.unique_thread_id == unique_thread_id);
    }

    public int hashCode() {
        // equals() compares unique_thread_id, so this has to hash the same
        // field.  It used to hash thread_id, which is 0 for every proxy the
        // agent builds through the constructor below -- that one is handed
        // only the unique id.  PStack puts its proxies into a HashMap keyed by
        // the proxies JavaThread hands out, where thread_id is set, and looks
        // them up with the agent's, where it is not.  The two are equal and
        // land in different buckets, so every lookup missed and pstack printed
        // no thread names and no Java frames at all.
        return Long.hashCode(unique_thread_id);
    }

    public String toString() {
        // Same two constructors: the agent's proxies have no thread_id, and
        // printing a column of zeroes for every thread is no use.  On the BSDs
        // other than macOS both numbers are the kernel's lwp id, so the unique
        // id is the right thing to fall back to.
        return Long.toString(thread_id != 0 ? thread_id : unique_thread_id);
    }

    public ThreadContext getContext() throws IllegalThreadStateException {
        long[] data = debugger.getThreadIntegerRegisterSet(unique_thread_id);
        ThreadContext context = BsdThreadContextFactory.createThreadContext(debugger);
        // null means we failed to get the register set for some reason. The caller
        // is responsible for dealing with the set of null registers in that case.
        if (data != null) {
            for (int i = 0; i < data.length; i++) {
                context.setRegister(i, data[i]);
            }
        }
        return context;
    }

    public boolean canSetContext() throws DebuggerException {
        return false;
    }

    public void setContext(ThreadContext context)
      throws IllegalThreadStateException, DebuggerException {
        throw new DebuggerException("Unimplemented");
    }

    /** this is not interface function, used in core file to get unique thread id on Macosx*/
    public long getUniqueThreadId() {
        return unique_thread_id;
    }
}
