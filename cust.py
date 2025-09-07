#!/usr/bin/env python
#
# Infrastructure Performance helper script
# Written to assist Infrastructure Performance personnel in daily monitoring tasks
#
# Dependencies:
# ~/.snc/customer_sysids.txt - list of sys_id's for your assigned customers, one per line
# ~/.jmp/ldap.pw - file containing your LDAP password
#
# TODO: Like jmp, use keychain instead of text file for password storage

CMDB_FQDN = "datacenter.service-now.com"
KIBANA_FQDN = "db31087.iad3.service-now.com"
URL_XMLSTATS = "http://%s:%s/xmlstats.do?include=transactions"
LIMIT = 999999
USECACHE = True

# We locally cache CMDB lookups for 1 day since they are slow. This controls the timeout.
CACHE_TIMEOUT=86400

import os
import sys
import math
import time
import datetime
import shelve
import urllib
import urllib2
import getopt
import threading
import Queue
from xml.dom import minidom
from subprocess import check_call
from ServiceNow import CMDB

env_user = os.getenv("USER")
env_password = None
pass_file = os.environ["HOME"] + "/.jmp/ldap.pw"
cust_file = os.environ["HOME"] + "/.snc/customer_sysids.txt"
shelf_file = os.environ["HOME"] + "/.snc/cust_cache.db"

now = datetime.datetime.now()

SCRIPT_NAME = "cust"
# note; 2.0.0 was the first python version
SCRIPT_VERSION = "0.5"
SCRIPT_COPYRIGHT = "(C) %d ServiceNow, Inc." % now.year
SCRIPT_AUTHOR = "Tim Yim"


def special_message():
    return check_call('osascript -e "set volume 7";say -v Zarvox -r 190 "I hate your face!";osascript -e "set volume 2"', shell=True)


def usage():
    """
    Shows program usage and options.
    """
    print SCRIPT_NAME + " v" + SCRIPT_VERSION
    print SCRIPT_COPYRIGHT
    print "by " + SCRIPT_AUTHOR
    print """
Options:
        * BASIC OPTIONS*
        -h/--help                    = this message
        -d/--dumpcache               = dump the local cache, force re-lookups
        -y/--yoface                  = special message

"""


# process commandline arguments
try:
    opts, args = getopt.getopt(sys.argv[1:], "hdy", ["help", "dumpcache", "yoface"])
except getopt.GetoptError, err:
    print str(err)
    usage()
    sys.exit(2)

for o, a in opts:
    if o in ("-h", "--help"):
        usage()
        sys.exit()
    elif o in ("-d", "--dumpcache"):
        USECACHE = False
    elif o in ("-y", "--yoface"):
        special_message()
        sys.exit()


ch, cw = os.popen('stty size', 'r').read().split()

fp = open(pass_file)
pw = fp.readline().rstrip()
if (len(pw) > 1):
	env_password = pw

# This is our local cache
c = shelve.open(shelf_file)
if ('version' not in c) or (c['version'] != SCRIPT_VERSION):
    USECACHE = False
    c['version'] = SCRIPT_VERSION

# Get list of instances from cache or CMDB
if USECACHE and ('instances' in c) and (int(time.time()) < (c['instances']['ts']+CACHE_TIMEOUT)):
	instances = c['instances']['value']
else:
    my_customers = open(cust_file).read().splitlines()
    QUERY = "customerIN" + ','.join(my_customers) + "^instance_attr=a8c3333a37760000dada8c00dfbe5d04^operational_status=1"
    cmdb = CMDB(CMDB_FQDN, env_user, env_password, "cmdb_ci_service_now", "name", 1)
    qdata = cmdb.query(__limit=LIMIT, __encoded_query=QUERY)
    instances = {}
    idx = 1
    for k in qdata:
        vd = qdata[k]
        for k0 in vd._keys():
            if (k0 == 'name'):
                name = vd[k0]
            if (k0 == 'dv_customer'):
                customer = vd[k0].partition(' ')[0]
            if (k0 == 'instance_id'):
                instance_id = vd[k0]
        instances[idx] = (name,customer,instance_id)
        idx += 1
    c['instances'] = { 'ts':int(time.time()), 'value':instances }


# Format for display
lines = []
for k, v in instances.iteritems():
    name, cust, instance_id = v
    if name.startswith(cust.lower()):
        lines.append(name)
    else:
        lines.append("%s (%s)" % (name, cust))

days = {1:("M","Mon","Monday"), 2:("T","Tue","Tuesday"), 3:("W","Wed","Wednesday"), 4:("Th","Thu","Thursday"), 5:("F","Fri","Friday")}
short_days = []
for k, v in days.iteritems():
    short_days.append(v[1])
cols = len(days)

max_line_plus_selector = len(max(lines, key=len)) + 5
max_col_width_for_terminal = ( int(cw) - 1 ) // cols
mylen = min(max_col_width_for_terminal, max_line_plus_selector) - 5


def instance_menu():
    fmt_str = "     {:<%d}" % mylen
    for d in zip(*[iter(short_days)]):
        print fmt_str.format(*d),
    print

    i = 1
    fmt_str = "{:>3}) {:<%d}" % mylen
    for l in lines:
        print fmt_str.format(i, l[:mylen]),
        if not i % cols: print
        i += 1
    print "\n"
    for k, v in days.iteritems():
        print fmt_str.format(v[0], "All " + v[2])
    print "  Q) Quit\n"


def invalid():
    print "INVALID CHOICE!"


def open_day(day):
    for dk, v in days.iteritems():
        if day == v[0]: break
    else:
        return False
    choices = []
    for ik, v in instances.iteritems():
        if dk == cols and ik % cols == 0:
            choices.append(v[0])
        else:
            if ik % cols == dk: choices.append(v[0])
    for instance in choices:
        report_anomalies(instance)
        open_kibana(instance)


def fetch_trans(url):
    # print "Fetching: %s" % url
    try:
        dom = minidom.parse(urllib2.urlopen(url, None, 10))
    except:
        return
    for element in dom.getElementsByTagName('transactions.mean'):
        return float(element.firstChild.nodeValue)


def report_anomalies(instance):
    instance_data = get_instance_data(instance)
    has_xxl = False
    if (instance_data['primary']['cap_size_desired'] == "xxlarge") or (instance_data['primary']['cap_size'] == "xxlarge"):
        has_xxl = True
    if (instance_data['primary']['cap_size_desired'] != instance_data['primary']['cap_size']) and not has_xxl:
        print "[%s] Desired Capacity: %s, Current Capacity: %s" % (instance, instance_data['primary']['cap_size_desired'], instance_data['primary']['cap_size'])
    urls = []
    for node in instance_data['nodes']:
        url = URL_XMLSTATS % (node['host'], node['port'])
        urls.append((url,))
    if (len(urls) < 8) and has_xxl:
            print "[%s] Database is configured as xxlarge and only has %s nodes per datacenter!" % (instance, len(urls) / 2)
    print "[%s] Checking TPS Report... (%s nodes)" % (instance, len(urls))
    result = run_parallel_in_threads(fetch_trans, urls)
    result.put(None)
    for avg in iter(result.get_nowait, None):
        if avg / 60 > 100:
            print "Has node with > 100 transactions per second. (%s)" % avg
            break


# http://stackoverflow.com/questions/3490173/how-can-i-speed-up-fetching-pages-with-urllib2-in-python
def run_parallel_in_threads(target, args_list):
    result = Queue.Queue()
    # wrapper to collect return value in a Queue
    def task_wrapper(*args):
        result.put(target(*args))
    threads = [threading.Thread(target=task_wrapper, args=args) for args in args_list]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return result


def open_kibana(instance):
    instance_data = get_instance_data(instance)
    params = {
        "title": instance,
        "query": "loghost:p%s.%s*" % (instance_data['primary']['port'], instance_data['primary']['host'].replace('.service-now.com', '')),
        "alias": "%s (P)" % instance_data['primary']['host'].replace('.service-now.com', ''),
        "from": "4d",
    }
    if 'standby' in instance_data:
        params['query'] += ",loghost:p%s.%s*" % (instance_data['standby']['port'], instance_data['standby']['host'].replace('.service-now.com', ''))
        params['alias'] += ",%s (S)" % instance_data['standby']['host'].replace('.service-now.com', '')
    qs = urllib.urlencode(params)
    args = "http://%s/kibana/index.html#/dashboard/script/slow.js?%s" % (KIBANA_FQDN, qs)
    check_call(["open", args])


def get_instance_data(instance):
    ck = 'ins_' + instance
    if USECACHE and (ck in c) and (int(time.time()) < (c[ck]['ts']+CACHE_TIMEOUT)):
        instance_data = c[ck]['value']
    else:
        for ik, v in instances.iteritems():
            if instance in v:
                instance_id = v[2]
                break

        instance_data = {"replicas":[], "nodes":[]}

        QUERY = "u_discovered_instance_id=" + instance_id + "^operational_status=1"
        cmdb = CMDB(CMDB_FQDN, env_user, env_password, "cmdb_ci_db_catalog", "sys_id", 1)
        qdata = cmdb.query(__limit=LIMIT, __encoded_query=QUERY)
        catalog_ids = []
        for k in qdata:
            vd = qdata[k]
            for k0 in vd._keys():
                if (k0 == 'dv_database_instance'):
                    catalog_ids.append(vd[k0])

        QUERY = "nameIN" + ','.join(catalog_ids)
        cmdb = CMDB(CMDB_FQDN, env_user, env_password, "cmdb_ci_db_mysql_instance", "name", 1)
        qdata = cmdb.query(__limit=LIMIT, __encoded_query=QUERY)
        for k in qdata:
            usage, host, port, cap_size, cap_size_disco, cap_size_desired = ("",)*6
            vd = qdata[k]
            # dv_u_capacity_size_actual_lb - RAM
            # dv_u_capacity_size_actual_ub - RAM
            # u_capacity_size_actual_lb
            # u_capacity_size_actual_ub
            for k0 in vd._keys():
                if (k0 == 'u_usage'): usage = vd[k0]
                if (k0 == 'dv_u_host'): host = vd[k0]
                if (k0 == 'tcp_port'): port = vd[k0]
                if (k0 == 'dv_u_disco_capacity_size'): cap_size_disco = vd[k0]
                if (k0 == 'dv_u_capacity_size'): cap_size = vd[k0]
                if (k0 == 'dv_u_desired_capacity_size'): cap_size_desired = vd[k0]
            idata = {"host":host, "port":port, "cap_size":cap_size, "cap_size_disco":cap_size_disco, "cap_size_desired":cap_size_desired}
            if (usage in ["primary", "standby"]):
                instance_data[usage] = idata
            if (usage == "read_replica"):
                instance_data["replicas"].append(idata)

        QUERY = "instance_name=" + instance
        cmdb = CMDB(CMDB_FQDN, env_user, env_password, "service_now_node", "sys_id", 1)
        qdata = cmdb.query(__limit=LIMIT, __encoded_query=QUERY)
        for k in qdata:
            name, host, port, scheduler_state = ("",)*4
            vd = qdata[k]
            for k0 in vd._keys():
                if (k0 == 'dv_u_host'): host = vd[k0]
                if (k0 == 'name'): name = vd[k0]
                if (k0 == 'tcp_port'): port = vd[k0]
                if (k0 == 'u_scheduler_state'): scheduler_state = vd[k0]
            if port == "": continue
            ndata = {"host":host, "port":port, "name":name, "scheduler_state":scheduler_state}
            if ndata not in instance_data["nodes"]:
                instance_data["nodes"].append(ndata)

        c[ck] = { 'ts':int(time.time()), 'value':instance_data }
    return instance_data


def handle_instance(instance):
    report_anomalies(instance)
    instance_data = get_instance_data(instance)
    print "Primary:"
    print "\tP) %s:%s" % (instance_data['primary']['host'], instance_data['primary']['port'])
    print
    if 'standby' in instance_data:
        print "Standby:"
        print "\tS) %s:%s" % (instance_data['standby']['host'], instance_data['standby']['port'])
        print
    if len(instance_data['replicas']) > 0:
        print "Read Replicas:"
        idx = 1
        for r in instance_data['replicas']:
            print "\t%d) %s:%s" % (idx, r['host'], r['port'])
            idx += 1
        print
    print "K) Open Primary/Standby in Kibana"
    ans = raw_input("Selection: ")
    if ans.isdigit() or ans in ["P", "S"]:
        jmp2host(instance, ans)
    if ans == "K":
        open_kibana(instance)


def jmp2host(instance, selector):
    instance_data = get_instance_data(instance)
    if selector == "P": k = 'primary'
    if selector == "S": k = 'standby'
    innotop2clipboard(instance_data[k]['port'])
    return check_call(["jmp", instance_data[k]['host']])


def innotop2clipboard(port):
    if port == "3306":
        socket = "/tmp/mysql.sock"
    else:
        socket = "/tmp/mysqld*%s.sock" % port
    return check_call("echo \"IPERF_SOCK=%s;mysql -A -S \$IPERF_SOCK -e 'SET GLOBAL long_query_time = 1';innotop --delay 1 --mode Q --socket \$IPERF_SOCK\" | pbcopy" % socket, shell=True)


while True:
    instance_menu()
    ans = raw_input("Selection: ")
    if ans.isdigit():
        instance = instances.get(int(ans),[None,invalid])[0]
        handle_instance(instance)
        break
    if not open_day(ans):
        break
    if ans == "Q": sys.exit()
