const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const c = std.c;
const assert = std.debug.assert;

extern "kernel32" fn AcquireSRWLockExclusive(lock: *windows.SRWLOCK) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *windows.SRWLOCK) void;
extern "kernel32" fn SleepConditionVariableSRW(
    condition_variable: *windows.CONDITION_VARIABLE,
    lock: *windows.SRWLOCK,
    milliseconds: windows.DWORD,
    flags: windows.ULONG,
) windows.BOOL;
extern "kernel32" fn WakeConditionVariable(condition_variable: *windows.CONDITION_VARIABLE) void;
extern "kernel32" fn WakeAllConditionVariable(condition_variable: *windows.CONDITION_VARIABLE) void;

pub const Mutex = if (builtin.os.tag == .windows) struct {
    srwlock: windows.SRWLOCK = windows.SRWLOCK_INIT,

    pub fn lock(self: *Mutex) void {
        AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn unlock(self: *Mutex) void {
        ReleaseSRWLockExclusive(&self.srwlock);
    }
} else struct {
    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        assert(c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
    }

    pub fn unlock(self: *Mutex) void {
        assert(c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
    }
};

pub const Condition = if (builtin.os.tag == .windows) struct {
    condition_variable: windows.CONDITION_VARIABLE = windows.CONDITION_VARIABLE_INIT,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        assert(SleepConditionVariableSRW(&self.condition_variable, &mutex.srwlock, std.math.maxInt(windows.DWORD), 0) != 0);
    }

    pub fn signal(self: *Condition) void {
        WakeConditionVariable(&self.condition_variable);
    }

    pub fn broadcast(self: *Condition) void {
        WakeAllConditionVariable(&self.condition_variable);
    }
} else struct {
    condition_variable: c.pthread_cond_t = c.PTHREAD_COND_INITIALIZER,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        assert(c.pthread_cond_wait(&self.condition_variable, &mutex.mutex) == .SUCCESS);
    }

    pub fn signal(self: *Condition) void {
        assert(c.pthread_cond_signal(&self.condition_variable) == .SUCCESS);
    }

    pub fn broadcast(self: *Condition) void {
        assert(c.pthread_cond_broadcast(&self.condition_variable) == .SUCCESS);
    }
};

pub fn Lifecycle(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: Mutex = .{},
        cond: Condition = .{},
        provider: ?*T = null,
        loading: bool = false,
        unloading: bool = false,
        reference_count: usize = 0,

        pub const Ref = struct {
            lifecycle: *Self,
            provider: *T,
            released: bool = false,

            pub fn release(self: *Ref) void {
                if (self.released) return;
                self.lifecycle.mutex.lock();
                assert(self.lifecycle.reference_count > 0);
                self.lifecycle.reference_count -= 1;
                if (self.lifecycle.unloading and self.lifecycle.reference_count == 0) {
                    self.lifecycle.cond.broadcast();
                }
                self.lifecycle.mutex.unlock();
                self.released = true;
            }
        };

        pub fn beginLoad(self: *Self) error{ProviderAlreadyLoaded}!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.unloading) self.cond.wait(&self.mutex);
            if (self.provider != null or self.loading) return error.ProviderAlreadyLoaded;
            self.loading = true;
        }

        pub fn abortLoad(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.loading) return;
            self.loading = false;
            self.cond.broadcast();
        }

        pub fn publish(self: *Self, provider: *T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            assert(self.loading);
            assert(self.provider == null);
            self.provider = provider;
            self.loading = false;
            self.cond.broadcast();
        }

        pub fn acquire(self: *Self) ?Ref {
            self.mutex.lock();
            defer self.mutex.unlock();
            const provider = self.provider orelse return null;
            self.reference_count += 1;
            return .{ .lifecycle = self, .provider = provider };
        }

        pub fn isLoaded(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.provider != null;
        }

        pub fn detachForUnload(self: *Self) ?*T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.loading or self.unloading) self.cond.wait(&self.mutex);
            const provider = self.provider orelse return null;
            self.provider = null;
            self.unloading = true;
            return provider;
        }

        pub fn awaitDrain(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.reference_count != 0) self.cond.wait(&self.mutex);
        }

        pub fn finishUnload(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            assert(self.unloading);
            self.unloading = false;
            self.cond.broadcast();
        }
    };
}

const TestProvider = struct {
    deinit_count: *usize,

    fn deinit(self: *TestProvider) void {
        self.deinit_count.* += 1;
    }
};

const TestStartGate = struct {
    mutex: Mutex = .{},
    cond: Condition = .{},
    arrived: usize = 0,
    released: bool = false,

    fn wait(self: *TestStartGate, total: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.arrived += 1;
        if (self.arrived == total) {
            self.released = true;
            self.cond.broadcast();
            return;
        }
        while (!self.released) self.cond.wait(&self.mutex);
    }
};

test "mutex serializes contended critical sections" {
    var mutex: Mutex = .{};
    var gate: TestStartGate = .{};
    var inside: usize = 0;
    var completed: usize = 0;
    const thread_count = 8;
    const rounds = 64;

    const Worker = struct {
        mutex: *Mutex,
        gate: *TestStartGate,
        inside: *usize,
        completed: *usize,

        fn run(self: *@This()) void {
            self.gate.wait(thread_count);
            for (0..rounds) |_| {
                self.mutex.lock();
                assert(self.inside.* == 0);
                self.inside.* = 1;
                self.inside.* = 0;
                self.completed.* += 1;
                self.mutex.unlock();
            }
        }
    };

    var workers: [thread_count]std.Thread = undefined;
    var ctx: [thread_count]Worker = undefined;
    for (0..thread_count) |i| {
        ctx[i] = .{ .mutex = &mutex, .gate = &gate, .inside = &inside, .completed = &completed };
        workers[i] = try std.Thread.spawn(.{}, Worker.run, .{&ctx[i]});
    }
    for (workers) |worker| worker.join();

    try std.testing.expectEqual(@as(usize, thread_count * rounds), completed);
    try std.testing.expectEqual(@as(usize, 0), inside);
}

test "lifecycle unload waits for the last release and deinit broadcasts" {
    var lifecycle: Lifecycle(TestProvider) = .{};
    var deinit_count: usize = 0;
    var provider = TestProvider{ .deinit_count = &deinit_count };
    try lifecycle.beginLoad();
    lifecycle.publish(&provider);
    var ref = lifecycle.acquire().?;

    const State = struct {
        mutex: Mutex = .{},
        cond: Condition = .{},
        detached: bool = false,

        fn markDetached(self: *@This()) void {
            self.mutex.lock();
            self.detached = true;
            self.cond.broadcast();
            self.mutex.unlock();
        }

        fn waitDetached(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.detached) self.cond.wait(&self.mutex);
        }
    };
    var state: State = .{};

    const Worker = struct {
        lifecycle: *Lifecycle(TestProvider),
        state: *State,
        fn run(self: *@This()) void {
            const detached = self.lifecycle.detachForUnload();
            assert(detached != null);
            self.state.markDetached();
            self.lifecycle.awaitDrain();
            detached.?.deinit();
            self.lifecycle.finishUnload();
        }
    };

    var worker = Worker{ .lifecycle = &lifecycle, .state = &state };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    state.waitDetached();
    ref.release();
    thread.join();

    try std.testing.expectEqual(@as(usize, 1), deinit_count);
    try std.testing.expect(!lifecycle.isLoaded());
}

test "concurrent load waits until unload drain completes" {
    var lifecycle: Lifecycle(TestProvider) = .{};
    var deinit_count: usize = 0;
    var provider = TestProvider{ .deinit_count = &deinit_count };
    try lifecycle.beginLoad();
    lifecycle.publish(&provider);
    var ref = lifecycle.acquire().?;

    const State = struct {
        mutex: Mutex = .{},
        cond: Condition = .{},
        detached: bool = false,
        attempted_load: bool = false,
        load_acquired: bool = false,

        fn markDetached(self: *@This()) void {
            self.mutex.lock();
            self.detached = true;
            self.cond.broadcast();
            self.mutex.unlock();
        }

        fn waitDetached(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.detached) self.cond.wait(&self.mutex);
        }

        fn markAttempted(self: *@This()) void {
            self.mutex.lock();
            self.attempted_load = true;
            self.cond.broadcast();
            self.mutex.unlock();
        }

        fn waitAttempted(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.attempted_load) self.cond.wait(&self.mutex);
        }

        fn markAcquired(self: *@This()) void {
            self.mutex.lock();
            self.load_acquired = true;
            self.cond.broadcast();
            self.mutex.unlock();
        }

        fn waitNotAcquired(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.load_acquired) self.cond.wait(&self.mutex);
        }

        fn waitAcquired(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.load_acquired) self.cond.wait(&self.mutex);
        }
    };
    var state: State = .{};

    const UnloadWorker = struct {
        lifecycle: *Lifecycle(TestProvider),
        state: *State,
        fn run(self: *@This()) void {
            const detached = self.lifecycle.detachForUnload();
            assert(detached != null);
            self.state.markDetached();
            self.lifecycle.awaitDrain();
            detached.?.deinit();
            self.lifecycle.finishUnload();
        }
    };

    const LoadWorker = struct {
        lifecycle: *Lifecycle(TestProvider),
        state: *State,
        fn run(self: *@This()) void {
            self.state.markAttempted();
            self.lifecycle.beginLoad() catch |err| switch (err) {
                error.ProviderAlreadyLoaded => return,
            };
            self.state.markAcquired();
            self.lifecycle.abortLoad();
        }
    };

    var unload_worker = UnloadWorker{ .lifecycle = &lifecycle, .state = &state };
    const unload_thread = try std.Thread.spawn(.{}, UnloadWorker.run, .{&unload_worker});
    state.waitDetached();

    var load_worker = LoadWorker{ .lifecycle = &lifecycle, .state = &state };
    const load_thread = try std.Thread.spawn(.{}, LoadWorker.run, .{&load_worker});
    state.waitAttempted();
    state.mutex.lock();
    const still_blocked = !state.load_acquired;
    state.mutex.unlock();
    try std.testing.expect(still_blocked);

    ref.release();
    unload_thread.join();
    load_thread.join();
    state.mutex.lock();
    const acquired = state.load_acquired;
    state.mutex.unlock();
    try std.testing.expect(acquired);

    try std.testing.expectEqual(@as(usize, 1), deinit_count);
}

test "abortLoad wakes unload waiters" {
    var lifecycle: Lifecycle(TestProvider) = .{};
    try lifecycle.beginLoad();

    const State = struct {
        mutex: Mutex = .{},
        cond: Condition = .{},
        waiting: bool = false,
        finished: bool = false,

        fn markWaiting(self: *@This()) void {
            self.mutex.lock();
            self.waiting = true;
            self.cond.broadcast();
            self.mutex.unlock();
        }

        fn waitWaiting(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.waiting) self.cond.wait(&self.mutex);
        }

        fn markFinished(self: *@This()) void {
            self.mutex.lock();
            self.finished = true;
            self.cond.broadcast();
            self.mutex.unlock();
        }

        fn waitFinished(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.finished) self.cond.wait(&self.mutex);
        }
    };
    var state: State = .{};

    const Worker = struct {
        lifecycle: *Lifecycle(TestProvider),
        state: *State,
        fn run(self: *@This()) void {
            self.state.markWaiting();
            const detached = self.lifecycle.detachForUnload();
            assert(detached == null);
            self.state.markFinished();
        }
    };

    var worker = Worker{ .lifecycle = &lifecycle, .state = &state };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    state.waitWaiting();
    lifecycle.abortLoad();
    state.waitFinished();
    thread.join();
}
