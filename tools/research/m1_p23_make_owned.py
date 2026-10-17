#!/usr/bin/env python3
"""P23 exact-source research copy: deferred M0 pool start + honest shutdown."""
import hashlib
from pathlib import Path
import sys

PIN = "e74d6a73f956c562eab176e27687a47249f5815d"

def change(src, old, new, label):
    if src.count(old) != 1:
        raise SystemExit(f"P23 source-anchor drift {label}: {src.count(old)}")
    return src.replace(old, new)

def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: p23_make_owned.py ORIGINAL GENERATED")
    raw = Path(sys.argv[1]).read_bytes()
    sha = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
    if sha != PIN:
        raise SystemExit(f"P23 M0 owned source mismatch: {sha}")
    s = raw.decode()
    s = change(s, "module concurrency.internal.owned_task;",
        "module concurrency.research.m1_p23_owned;", "module")
    s = change(s, "import std.traits :\n    ReturnType;",
        "import std.traits :\n    ReturnType;\n"
        "import core.sync.semaphore : Semaphore;\n"
        "import core.stdc.stdlib : abort;", "imports")
    s = change(s, """    private enum Lifecycle : ubyte
    {
        running,
        draining,
        stopped
    }""", """    private enum Lifecycle : ubyte
    {
        constructed,
        starting,
        running,
        draining,
        shutdownUncertain,
        joinedStopped
    }""", "states")
    old = """    private Throwable _shutdownFailure;

    this(size_t workers, size_t ingressCapacity, size_t maxRetained = 4096)
    {
        if (maxRetained == 0)
            throw new Exception("maxRetained must be positive");

        _pool = new SubmissionWorkerPool(
            workers, ingressCapacity, &markReturned);
        _mutex = new Mutex();
        _lifecycleChanged = new Condition(_mutex);
        _lifecycle = Lifecycle.running;
        _maxRetained = maxRetained;
    }"""
    new = """    private Throwable _shutdownFailure;
    private size_t _workers, _capacity, _joinClaims, _waiters;
    private bool _injectPreJoin, _injectAfterStart, _synthetic;
    private Semaphore _preJoinGate;

    // No native thread starts until a separate supervisor owns this object.
    this(size_t workers, size_t ingressCapacity, size_t maxRetained = 4096)
    {
        if (!workers || !ingressCapacity || !maxRetained)
            throw new Exception("P23 dimensions must be positive");
        _mutex = new Mutex();
        _lifecycleChanged = new Condition(_mutex);
        _lifecycle = Lifecycle.constructed;
        _workers = workers;
        _capacity = ingressCapacity;
        _maxRetained = maxRetained;
    }

    void researchStart() @system
    {
        synchronized (_mutex)
        {
            if (_lifecycle != Lifecycle.constructed)
                throw new Exception("P23 start is single-use");
            _lifecycle = Lifecycle.starting;
        }
        SubmissionWorkerPool candidate;
        try
            candidate = new SubmissionWorkerPool(_workers, _capacity,
                &markReturned);
        catch (Throwable)
            abort(); // unknown real post-launch start: fail-stop
        synchronized (_mutex)
        {
            _pool = candidate;
            if (_injectAfterStart)
            {
                _synthetic = true;
                _shutdownFailure = new Exception("P23 synthetic after-start");
                _lifecycle = Lifecycle.shutdownUncertain;
            }
            else
                _lifecycle = Lifecycle.running;
            _lifecycleChanged.notifyAll();
        }
    }

    void researchInjectAfterStart() @system
    {
        synchronized (_mutex)
        {
            if (_lifecycle != Lifecycle.constructed)
                throw new Exception("P23 after-start hook too late");
            _injectAfterStart = true;
        }
    }

    void researchInjectPreJoin(Semaphore gate) @system
    {
        synchronized (_mutex)
        {
            if (_lifecycle != Lifecycle.running || gate is null)
                throw new Exception("P23 pre-join hook too late");
            _injectPreJoin = true;
            _preJoinGate = gate;
        }
    }

    bool researchConstructed()
    {
        synchronized (_mutex)
            return _lifecycle == Lifecycle.constructed;
    }

    bool researchUncertain()
    {
        synchronized (_mutex)
            return _lifecycle == Lifecycle.shutdownUncertain;
    }

    size_t researchWaiters()
    {
        synchronized (_mutex)
            return _waiters;
    }

    size_t researchJoinClaims()
    {
        synchronized (_mutex)
            return _joinClaims;
    }

    void researchJoinKnownSynthetic() @system
    {
        synchronized (_mutex)
        {
            if (!_synthetic || _pool is null ||
                _lifecycle != Lifecycle.shutdownUncertain)
                throw new Exception("P23 native failure retry prohibited");
            _lifecycle = Lifecycle.draining;
            ++_joinClaims;
        }
        try
            _pool.closeAndJoin();
        catch (Throwable)
            abort(); // real native join failure is NOT recoverable here
        synchronized (_mutex)
        {
            foreach (ref entry; _retained)
                entry = RetainedTask.init;
            _retained.length = 0;
            _synthetic = false;
            _shutdownFailure = null;
            _lifecycle = Lifecycle.joinedStopped;
            _lifecycleChanged.notifyAll();
        }
    }"""
    s = change(s, old, new, "deferred ownership and start")
    s = change(s, """        synchronized (_mutex)
        {
            final switch (_lifecycle)
            {
                case Lifecycle.running:
                    _lifecycle = Lifecycle.draining;
                    break;

                case Lifecycle.draining:
                    while (_lifecycle != Lifecycle.stopped)
                        _lifecycleChanged.wait();

                    if (_shutdownFailure !is null)
                        throw _shutdownFailure;
                    return;

                case Lifecycle.stopped:
                    if (_shutdownFailure !is null)
                        throw _shutdownFailure;
                    return;
            }
        }""", """        synchronized (_mutex)
        {
            while (_lifecycle == Lifecycle.starting)
                _lifecycleChanged.wait();
            final switch (_lifecycle)
            {
                case Lifecycle.constructed:
                    throw new Exception("P23 not started");
                case Lifecycle.starting:
                    assert(0);
                case Lifecycle.running:
                    _lifecycle = Lifecycle.draining;
                    ++_joinClaims;
                    break;
                case Lifecycle.draining:
                    ++_waiters;
                    while (_lifecycle == Lifecycle.draining)
                        _lifecycleChanged.wait();
                    if (_shutdownFailure !is null)
                        throw _shutdownFailure;
                    return;
                case Lifecycle.shutdownUncertain:
                    throw _shutdownFailure;
                case Lifecycle.joinedStopped:
                    return;
            }
        }""", "concurrent state arbitration")
    s = change(s, """        try
        {
            _pool.closeAndJoin();
        }
        catch (Throwable error)""", """        try
        {
            if (_injectPreJoin)
            {
                _preJoinGate.wait();
                throw new Exception("P23 synthetic before-native-join");
            }
            _pool.closeAndJoin();
        }
        catch (Throwable error)""", "prejoin seam")
    s = change(s, """        catch (Throwable error)
        {
            failure = error;
        }""", """        catch (Throwable error)
        {
            // A real native join failure leaves worker liveness unknown.
            // Only a known synthetic pre-join fault may return here.
            if (!_injectPreJoin)
                abort();
            failure = error;
        }""", "native-failure fail-stop")
    s = change(s, """            _shutdownFailure = failure;
            _lifecycle = Lifecycle.stopped;
            _lifecycleChanged.notifyAll();""", """            _shutdownFailure = failure;
            _synthetic = failure !is null && _injectPreJoin;
            _lifecycle = failure is null
                ? Lifecycle.joinedStopped : Lifecycle.shutdownUncertain;
            _lifecycleChanged.notifyAll();""", "honest terminal phase")
    s = change(s, "return _lifecycle == Lifecycle.stopped;",
        "return _lifecycle == Lifecycle.joinedStopped;", "joined predicate")
    dst = Path(sys.argv[2])
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(s)
    print("P23_SOURCE_PIN_PASS " + sha)

if __name__ == "__main__":
    main()
