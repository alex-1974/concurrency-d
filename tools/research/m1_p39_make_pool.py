#!/usr/bin/env python3
"""Generate P39 notification-site counters from pinned P38 research pool."""
from pathlib import Path
import subprocess
import sys

def once(s,old,new):
    if s.count(old)!=1:
        raise ValueError("P39 source anchor drift: "+old[:80])
    return s.replace(old,new,1)

def main():
    root,source,out=map(Path,sys.argv[1:4])
    temp=out.with_suffix(".p38.tmp")
    try:
        subprocess.run([sys.executable,str(root/"tools/research/m1_p38_make_pool.py"),
                        str(root),str(source),str(temp)],check=True)
        s=temp.read_text()
    finally:
        temp.unlink(missing_ok=True)
    s=once(s,"module concurrency.research.m1_p38_pool;",
           "module concurrency.research.m1_p39_pool;")
    s=once(s,"private final class TaskInbox",
        """package(concurrency) struct P39NotificationStats
{
    ulong publish, localWork, closeAll, finalCompletionAll;
}
private final class TaskInbox""")
    s=once(s,"    private size_t _parkCount;",
        """    private size_t _parkCount;
    private P39NotificationStats _p39Notifications;""")
    def instrument(s,start,end,old,repl):
        i=s.index(start)
        j=s.index(end,i)
        body=once(s[i:j],old,repl)
        return s[:i]+body+s[j:]
    s=instrument(s,"    SubmissionResult trySubmit(TaskRef task)",
        "    bool hasCapacity()",
        "            _changed.notify();",
        "            ++_p39Notifications.publish;\n            _changed.notify();")
    s=instrument(s,"    void announceLocalWork()",
        "    void parkUnlessChanged(size_t observed)",
        "            _changed.notify();",
        "            ++_p39Notifications.localWork;\n            _changed.notify();")
    s=instrument(s,"    void close()",
        "    size_t wakeGeneration()",
        "            _changed.notifyAll();",
        "            ++_p39Notifications.closeAll;\n            _changed.notifyAll();")
    s=instrument(s,"    void completeOne()",
        "    void close()",
        "                _changed.notifyAll();",
        "                ++_p39Notifications.finalCompletionAll;\n                _changed.notifyAll();")
    start=s.index("private final class TaskInbox")
    pos=s.index("    size_t acceptedCount()",start)
    s=s[:pos]+"""    P39NotificationStats researchNotificationStats()
    {
        synchronized (_mutex)
            return _p39Notifications;
    }

"""+s[pos:]
    pool=s.index("package(concurrency) final class SubmissionWorkerPool")
    before,after=s[:pool],s[pool:]
    after=once(after,"    P38WorkerCounters[] researchWorkerCounters()",
        """    P39NotificationStats researchNotificationStats()
    {
        if (!_p38Joined)
            throw new Exception("P39 counters require joined workers");
        return _inbox.researchNotificationStats();
    }

    P38WorkerCounters[] researchWorkerCounters()""")
    s=before+after
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(s)
    print("P39_NOTIFICATION_SITES_GENERATED source_pinned=true")

if __name__=="__main__":
    main()
