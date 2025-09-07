transactions() {
    local OPTIND=1
    local EXCESSIVE=0
    local PAGE=""
    local USER=""
    local COUNT=20
    local SORT=2
    local REVERSE=1
    local TOTAL=0
    local LLINES=0
    local ID=""
    while getopts ":ep:u:c:s:rtli:" O; do
        case "${O}" in
            e)  EXCESSIVE=1 ;;
            p)  PAGE="${OPTARG}" ;;
            u)  USER="${OPTARG}" ;;
            c)  COUNT="${OPTARG}" ;;
            s)  SORT="${OPTARG}" ;;
            r)  REVERSE=0 ;;
            t)  TOTAL=1 ;;
            l)  LLINES=1 ;;
            i)  ID=$(echo "${OPTARG}" | sed -rn 's/^#?([0-9]+(,[0-9]+)*),?$/\1/p') ;;
            \?) echo "Unknown option: ${OPTARG}" >&2 ;;
            :)  echo "Option requires an argument: ${OPTARG}" >&2 ;;
        esac
    done
    shift $((OPTIND-1))

    if [ "${ID}" ]; then
        $([ -n "$1" -a ! -r "$1" ] && echo "sudo") zcat -f -- "$@" \
        | awk -v ID="${ID}" '
            BEGIN {
                RS = "[0-9]+-[0-9]+-[0-9]+ [0-9]+:[0-9]+:[0-9]+ \\([0-9]+\\) "
                ID = "#" ID ","
            }

            $4 == "Start" && $5 == ID {
                printf("%s%s", RT3, prev)
                thread = $1 "(.[0-9])?"
                session_id = $2
            }

            $1 ~ thread && $2 == session_id {
                printf("%s%s", RT2, $0)
            }

            $4 == "End" && $5 == ID {
                thread = session_id = ""
            }

            {
                RT3 = RT2
                RT2 = RT
                prev = $0
            }'
    else
        local TEMP=$(mktemp -t transactions.XXX || exit 1)
        $([ -n "$1" -a ! -r "$1" ] && echo "sudo") zcat -f -- "$@" \
        | grep '\*\*\* End  #' \
        | awk -v PAGE="${PAGE}" -v USER="${USER}" -v EXCESSIVE="${EXCESSIVE}" -v TOTAL="${TOTAL}" -v LLINES="${LLINES}" -v COUNT="${COUNT}" '
            { rawline = $0; gsub(/,/, "", $0) }
            EXCESSIVE && $13 != "EXCESSIVE" { next }
            PAGE && $10 !~ PAGE { next }
            USER && $12 !~ USER { next }

            LLINES {
                if(i++ >= COUNT)
                    exit
                print rawline
                next
            }

            {
                if(TOTAL)
                    search = "total"    
                else if(PAGE && USER)
                    search = $10 "+" $12
                else if(PAGE)
                    search = $12
                else
                    search = $10

                if($13 == "EXCESSIVE")
                    timestamp = $15
                else
                    timestamp = $14

                split(timestamp, t, ":")
                time = (t[1] * 60 + t[2]) * 60 + t[3]
                total[search] += time
                num[search]++
            }

            END {
                for(search in total)
                    printf("%s\t% 8d\t% 7d\t% 8.02f\n", search, total[search] + .5, num[search], total[search] / num[search])
            }' > "${TEMP}"

        if [ "${LLINES}" -eq 1 ]; then
            cat "${TEMP}"
        else
            sort -nk "${SORT},${SORT}" $([ "${REVERSE}" -eq 1 ] && echo "--reverse") "${TEMP}" \
            | head -n "${COUNT}" \
            | sed '1iresult\t seconds\t  count\t average' \
            | column -ts $'\t'
        fi
        rm -f "${TEMP}"
    fi

# NAME
#   transactions -- ServiceNow transaction analysis tool
#
# SYNOPSIS
#   transactions [OPTION] [FILE ...]
#
# DESCRIPTION
#   The transactions utility allows you to get a summary of transactions for one or multiple ServiceNow log files. It is possible to pipe a part of a log file to this function if for example a window needs to be checked.
#
#   The following columns will be displayed:
#
#   search  The transaction matching the search.
#   seconds The total amount of time spent processing.
#   count   The total amount of transactions found.
#   average The average amount of time spent processing.
#
#   The following options are available:
#
#   -e      Only include EXCESSIVE transactions in the results.
#   -p rgx  Only include transactions where the path matches the given regular expression. This will automatically break the results down by user. Note that "task.do" will also match "incident_task.do", but "/task.do" will not.
#   -u rgx  Only include transactions where the user matches the given regular expression.
#   -c num  Print num number of results. If this option is omitted it defaults to 20.
#   -s num  Sort the results by column number num. If this option is omitted it defaults to 2. No sorting is performed when the -l option is used.
#   -r      Reverse the sorting order. The default sorting order is descending, so specifying this option would make it ascending.
#   -t      Group all results together and show the total.
#   -l      Print the actual log lines matching the search. Limited to the number of lines as specified with the -c option.
#   -i tid  Print all the logs line matching a particular transaction id, for example 15,460. Ignores all other options.
#
# EXAMPLES
#   The command:
#       transactions localhost_log.2013-09-02.txt
#   will show the top 20 pages with the highest total processing time.
#
#   The command:
#       transactions -ec 10 -s 3 localhost_log.2013-09-02.txt
#   will show the top 10 pages with the highest count of excessive transactions.
#
#   The command:
#       transactions -ep /home.do localhost_log.2013-09-02.txt
#   will show the top 20 users with the highest amount of total processing time for excessive home pages.
#
#   The command:
#       transactions -p . -s 3 localhost_log.2014-09-0{2,3,4}.txt
#   will show the top 20 users with the highest highest number of requests over the course of three days.
#
# KNOWN ISSUES
#   Using the -i mode, a transaction will not be found if the start of the transaction is in a different log file.
}

transactions 