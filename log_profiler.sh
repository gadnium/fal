log_profiler() {
    local OPTIND=1
    local INTERVAL=5
    local QUIET=0
    local VERBOSE=0
    while getopts ":i:qv" o; do
        case "${o}" in
            i)
                INTERVAL="${OPTARG}"
                ;;
            q)
                QUIET=1
                ;;
            v)
                VERBOSE=1
                ;;    
            \?)
                echo "Unknown option: ${OPTARG}" >&2
                ;;
            :)
                echo "Option requires an argument: ${OPTARG}" >&2
                ;;
        esac
    done
    shift $((OPTIND-1))

    sudo zcat -f "$@" | gawk -v INTERVAL="${INTERVAL}" -v QUIET="${QUIET}" -v VERBOSE="${VERBOSE}" '
        BEGIN {
            RS = "[0-9]+-[0-9]+-[0-9]+ [0-9]+:[0-9]+:[0-9]+ \\([0-9]+\\) "
            SPACE = " "
            EMPTY = ""
            NEWLINE = "\n"
            HEADER = 24
            INTERVAL *= 60

            reset()
        }

        RT_old {
            lines++
            split(RT_old, timestamp, SPACE)
            current = mktime2(timestamp[1], timestamp[2])
            if(current >= interval_end) {
                if(interval_end)
                    flush()
                day_start = mktime2(timestamp[1], "00:00:00")
                extra_seconds = (current - day_start) % INTERVAL
                interval_start = current - extra_seconds
                interval_end = interval_start + INTERVAL
            }
        }

        {
            RT_old = RT
            split($0, multi, NEWLINE)
            $0 = multi[1]
            multi_lines += length(multi) 
        }

        /Start  #/ { trans++; next }
        /EXCESSIVE/ { excessive++; next }
        /Memory transaction:/ { addmem($7, $11); next }
        /Script: Before GC/ { addmem($11, $9); next }         
        /Memory: After GC/ { addmem($9, $7); next }
        /Connection [0-9]+ in use for/ { in_use++; next }

        /SEVERE/ {
            severe++
            /Java heap space/                           && message("Out of memory: Java heap space")
            /Too many open files/                       && message("Too many open files - capture lsof command output")
            /Database connections exhausted!/           && message("Database connections exhausted - check wrapper log")
        }

        /WARNING/ {
            warning++
            /Starting cache flush/                      && message("Cache flush")
            /Lazy Writer Queue is long/                 && message("Lazy Writer Queue is long")
            /Communications link failure/               && message("Communications link failure - lost database connection")
            /Slow query logging disabled/               && message("Slow query logging disabled due to low database throughput")
            VERBOSE && /extremely large result set:/    && message(sprintf("Extremely large result set: %s records from %s %s", $NF, chunk(multi[2], 9), chunk(multi[2], 12) ) )
        }

        /glide Base path:/                              && message("Starting JVM")
        /Initiating normal shutdown/                    && message("Shutting down JVM")
        /Gobbled: Starting Glide Dist Upgrade/          && message("Starting upgrade")
        /Destroying transient database pool/            && message("Destroying database pool")
        /^glide\.clone.*Starting task/                  && message(sprintf("Clone: starting task %s", $NF))
        /^Committing update set:/                       && message(sprintf("Committing update set: %s", between($0, ": ", " SYSTEM")))
        VERBOSE && /Compacting table since/             && message("Compacting table - may cause table lock")

        END {
            flush()
        }

        function flush() {
            if(!lines)
                return

            if(!(flushcount++ % HEADER))
                printf("\033[0m%s   lines    logs   error    warn   trans   exces    used     mem\n", strftime("%y-%m-%d", interval_start))

            if(current > interval_end)
                window = interval_end - interval_start
            else
                window = current - interval_start

            thres = trans + .1
            l = strftime("%T", interval_start)
            l = l pretty(multi_lines, 8, 0, 0)
            l = l pretty(lines, 8, 0, 0)
            l = l pretty(severe, 8, thres / 100, thres / 10)
            l = l pretty(warning, 8, 0, 0)
            l = l pretty(trans, 8, 1, 0)
            l = l pretty(excessive, 8, thres / 10, thres / 5)
            l = l pretty(in_use, 8, window / 60, window / 30)
            l = l pretty(calcmem(), 8, 80, 90)

            print l
            reset()
        }

        function reset() {
            prev_msg = EMPTY
            multi_lines = lines = severe = warning = trans = excessive = in_use = 0
        }

        function pretty(value, width, yellow_thres, red_thres) {
            chars = length(value)
            if(yellow_thres < red_thres) {
                if(value >= red_thres)
                    value = red(value)
                else if(value >= yellow_thres)
                    value = yellow(value)
            } else {
                if(value < red_thres)
                    value = red(value)
                else if(value < yellow_thres)
                    value = yellow(value)
            }

            return sprintf("%" (width - chars) "s%s", EMPTY, value)
        }

        function message(msg) {
            if(QUIET || msg == prev_msg)
                return

            flush()
            flushcount = 0
            interval_start = current
            prev_msg = msg
            print white(msg)
            next
        }

        function chunk(str, num) {
            split(str, words, SPACE)
            return words[num]
        }

        function between(str, start, end) {
            start_index = index(str, start) + length(start)
            end_index = index(str, end) 
            if(!end_index)
                end_index = length(str) + 1
            return substr(str, start_index, end_index - start_index)
        }

        function mktime2(date, time) {
            datetime = date SPACE time
            gsub(/[^0-9]/, SPACE, datetime)
            return mktime(datetime)
        }

        function addmem(used, total) {
            gsub(/[^0-9]/, EMPTY, used)
            gsub(/[^0-9]/, EMPTY, total)
            
            if(used && total) {
                used_arr[NR] = used + 0
                total_arr[NR] = total + 0
            }
        }

        function calcmem() {
            if(!length(used_arr))
                return

            avg_used = avg(used_arr)
            max_total = max(total_arr)

            delete used_arr
            delete total_arr

            return sprintf("%d" , avg_used / max_total * 100 + .5) + 0
        }

        function max(arr) {
            x = 0
            for(a in arr)
                if(arr[a] > x)
                    x = arr[a]
            return x
        }

        function avg(arr) {
            count = sum = 0
            for(a in arr) {
                count++
                sum += arr[a]
            }
            return sum / count
        }

        function red(str)       { return sprintf("\033[1;31m%s\033[0m", str) }
        function yellow(str)    { return sprintf("\033[1;33m%s\033[0m", str) }
        function white(str)     { return sprintf("\033[1;37m%s\033[0m", str) }
        '
# NAME
#   log_profiler -- ServiceNow log file profiling utility
#
# SYNOPSIS
#   log_profiler [-i num] [-q] [-v] [file ...]
#
# DESCRIPTION
#   The log_profiler utility allows you to get a summary of events for one or multiple ServiceNow log files. When multiple log files are provided these are required to be in chronological order. The utility will try to color potential issues red or yellow based on fixed thresholds. These thresholds should only be used as a guideline.
#
#   The following columns will be displayed:
#
#   time    The date or time of the start of the interval. After a message is printed the start of the next interval is set to the time of the message.
#   lines   Number of lines parsed from the log file.
#   logs    Number of log statements parsed. A single log statement can be multiple lines.
#   error   Number of severe errors logged.
#   warn    Number of warnings logged.
#   trans   Number of transactions that started. A single transaction can have multiple (AJAX) requests.
#   exces   Number of excessive transactions that finished. This indicates slowness.
#   used    Number of warnings for long running queries. This indicates database contention.
#   mem     Average percentage of used memory.
#
#   The following options are available:
#
#   -i num  Print summarized log information in an interval of num minutes. The default is 5.
#   -q      Quiet mode: do not print any messages.
#   -v      Verbose mode: print extra messages that are usually not causing any issues, but may be relevant sometimes.
#
# EXAMPLES
#   The command:
#       log_profiler localhost_log.2013-09-02.txt
#   will profile a log file with a 5 minute interval with standard messages.
#
#   The command:
#       log_profiler -vi 1 localhost_log.2013-09-02.txt
#   will profile a log file with a 1 minute interval with additional messages.
#
#   The command:
#       log_profiler -qi 60 localhost_log.2014-09-0{2,3,4}.txt
#   will profile three consecutive log files with a 60 minute interval without messages.
#
}
