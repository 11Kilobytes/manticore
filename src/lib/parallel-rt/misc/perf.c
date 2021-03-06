/* perf.c
 *
 * COPYRIGHT (c) 2009 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 */

#include "manticore-rt.h"
#include "options.h"
#include "vproc.h"
#include "perf.h"
#include "topology.h"

#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <errno.h>

#include <linux/unistd.h>

#include <assert.h>
#include <unistd.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <inttypes.h>

static bool	ReportStatsFlg = false;	// true for report enabled
static bool	CSVStatsFlg = false;	// true for CSV-format report
static bool	SMLStatsFlg = false;	// true for SML-format report

#define __NR_perf_counter_open 298

static inline int
perf_counter_open(struct perf_counter_attr *attr,
                      pid_t pid, int cpu, int group_fd,
                      unsigned long flags)
{
    return syscall(__NR_perf_counter_open, attr, pid, cpu, group_fd, flags);
}

/* process command-line args */
void ParsePerfOptions (Options_t *opts)
{
    const char *report = GetStringEqOpt (opts, "-perf", "summary");

    if (report != 0) {
        ReportStatsFlg = true;
        if (strstr(report, "csv") != 0) CSVStatsFlg = true;
        if (strstr(report, "sml") != 0) SMLStatsFlg = true;
    }
}

void initCounter(PerfCntrs_t *p)
{
    p->nonGC = 0;
    p->GC = 0;
    p->last = 0;
    p->inGC = false;
    p->fd = -1;
}

// Forces a state transition, which updates the counter value
// members a final time.
void stopCounter(PerfCntrs_t *p)
{
    if (!p->enabled)
        return;

    if (p->inGC)
    {
        PERF_StopGC(p);
    }
    else
    {
        PERF_StartGC(p);
    }

    close (p->fd);
    p->fd = -1;
}

/* InitPerfCounters:
 *
 * Initialize the perf counters for the given vproc.
 */
void InitPerfCounters (VProc_t *vp)
{
    struct perf_counter_attr attr;
    int cpu = -1;

    if (vp->location == Location(LocationNode(vp->location), 0, 0)) {
        vp->reads.enabled = true;
        vp->misses.enabled = true;
    } else {
        vp->reads.enabled = false;
        vp->misses.enabled = false;
        return;
    }        

    int core = (vp->location >> LOC_THREAD_BITS) & ((1 << LOC_CORE_BITS) - 1);
    
    memset (&attr, 0, sizeof(attr));
    attr.sample_type = PERF_SAMPLE_IP | PERF_SAMPLE_TID;
    attr.freq = 0;
    
    attr.type = PERF_TYPE_RAW;
    attr.config = 0xF74E0;
    //fprintf (stderr, "Core %d = %x mask, %x config\n", core, mask, attr.config);
    attr.inherit = 0;
    attr.size = sizeof(struct perf_counter_attr);

    initCounter (&vp->reads);
    vp->reads.fd = perf_counter_open (&attr, 0, cpu, -1, 0);

    attr.config = 0xF74E1;
    initCounter (&vp->misses);
    vp->misses.fd  = perf_counter_open (&attr, 0, cpu, vp->reads.fd, 0);
}

void ReportPerfCounters () {
    if (! ReportStatsFlg)
	return;

    FILE *StatsOutFile = stderr;

    for (int i = 0;  i < NumVProcs;  i++) {
        VProc_t *vp = VProcs[i];
        stopCounter (&vp->reads);
        stopCounter (&vp->misses);
    }
    
    if (CSVStatsFlg) {
        if ((StatsOutFile = fopen ("perf.csv", "w")) == 0)
            StatsOutFile = stderr;

        for (int i = 0;  i < NumVProcs;  i++) {
            VProc_t *vp = VProcs[i];
            if (vp->misses.enabled)
                fprintf(StatsOutFile, "%" PRIi64 ", %" PRIi64 ", %" PRIi64 ", %" PRIi64 ", %" PRIi64 "\n", i, vp->misses.nonGC, vp->misses.GC, vp->reads.nonGC, vp->reads.GC);
        }

        fclose (StatsOutFile);
    }
    else if (SMLStatsFlg) {
        if ((StatsOutFile = fopen ("perf.sml", "w")) == 0)
            StatsOutFile = stderr;

        for (int i = 0;  i < NumVProcs;  i++) {
            VProc_t *vp = VProcs[i];
            
            if (vp->misses.enabled)
                fprintf (StatsOutFile,
                         "PST{processor=%d, \n\
                      nonGCmiss=%" PRIi64 ", GCmiss=%" PRIi64 ",\n                    \
                      nonGCreferences=%" PRIi64 ", GCreferences=%" PRIi64 "} ::\n",
                         i, vp->misses.nonGC, vp->misses.GC,
                         vp->reads.nonGC, vp->reads.GC);
        }

        fprintf (StatsOutFile, "nil\n");

        fclose (StatsOutFile);
    }
    else {
        for (int i = 0;  i < NumVProcs;  i++) {
            VProc_t *vp = VProcs[i];
            
            if (vp->misses.enabled)
                fprintf(stderr, "vproc %d, %" PRIi64 " nonGC misses, %" PRIi64 " GC misses, %" PRIi64 " nonGC reads, %" PRIi64 " GC reads\n",
                        i, vp->misses.nonGC, vp->misses.GC, vp->reads.nonGC, vp->reads.GC);
        }
    }

}

void PERF_StartGC(PerfCntrs_t *p)
{
    if (!p->enabled)
        return;

    assert(!p->inGC);

    unsigned long long count;
    int ignored = read(p->fd, &count, sizeof(count));

    p->nonGC += (count - p->last);
    p->last = count;

    p->inGC = true;
}

void PERF_StopGC(PerfCntrs_t *p)
{
    if (!p->enabled)
        return;

    assert(p->inGC);

    unsigned long long count;
    int ignored = read(p->fd, &count, sizeof(count));

    p->GC += (count - p->last);
    p->last = count;
    
    p->inGC = false;
}
