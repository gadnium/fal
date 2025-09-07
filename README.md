# Just some old stuff 
Hi fal guys!

This is a small handful of some of the infra / devops scripts and content I've written in the past just as a small showcase.

I will be your most cracked engineer on the team!


# Set the stage / context

This was all from my time in the trenches at ServiceNow which was all bare metal and no cloud tech. We had to build everything from scratch. Landing and stacking 2 full racks per day really sets the tone for automation. 

## Orchestration

We had Puppet for images and internal repo mirrors for our golden images but that's about it. We had a Workflow automation system built into ServiceNow (Like AirFlow) The set of scripts is what happens in the gaps of the automations.


## jmp

The first tool I wrote is called [jmp](https://github.com/gadnium/fal/tree/main/jmp) and it was a shorthand method to ssh'ing into any of our 10s of thousands of physical hosts.

## Now you can use jmp in other operations

The first example is in [inno.sh](https://github.com/gadnium/fal/blob/main/inno.sh). This one allows you to pass in a simple cluster ID and it would reply with a menu option of all the nodes connected to that cluster and allow you to directly connect to a specific node of your choice.

## Direct to serial port OOB
We also needed to connect directly to the chassis in case the OS was borked so I wrote helpers there too: [idrac.sh](https://github.com/gadnium/fal/blob/main/idrac.sh)



# The main script!

[FAIL-LIVE-generic.sh](https://github.com/gadnium/fal/blob/main/FAIL-LIVE-generic.sh) is going to be a full version of what it means to close the gaps. This was a primary/secondary cluster failover script that was used as a break-glass whenever the full workflow failed. Which was all the time! Check out the cool use-case of [screen](https://github.com/gadnium/fal/blob/main/FAIL-LIVE-generic.sh#L356) for capturing log file of your remote sessions!


# Advanced script
[named_pipes.sh](https://github.com/gadnium/fal/blob/main/named_pipes.sh) is probably one of the more advanced scripts we needed to write as we went through scale and were dealing with ever more processes to run. This helped us run multiple scripts sort of as a process manager.




# Analytics

We also wanted the ability to process our application log files cheaper than what Splunk was charging so I wrote a couple of massive gawk scripts.

- One for [transactions.sh](https://github.com/gadnium/fal/blob/main/transactions.sh)

- And another for profiling the log itself [log_profiler.sh](https://github.com/gadnium/fal/blob/main/log_profiler.sh)

# Various scripts and explanations:

- [memmon2.sh](https://github.com/gadnium/fal/blob/main/memmon2.sh) was a real script related to the MySQL 12 code perf problem I called out in the video. We had to constantly monitor the optimizer and kill any specific queries that would take down the system.
