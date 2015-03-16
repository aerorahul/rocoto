##########################################
#
# Module WorkflowMgr
#
##########################################
module WorkflowMgr

  ##########################################
  #
  # Class LSFBatchSystem 
  #
  ##########################################
  class LSFBatchSystem

    require 'workflowmgr/utilities'
    require 'fileutils'
    require 'etc'

    @@qstat_refresh_rate=30
    @@max_history=3600*1

    #####################################################
    #
    # initialize
    #
    #####################################################
    def initialize

      # Initialize an empty hash for job queue records
      @jobqueue={}

      # Initialize an empty hash for job accounting records
      @jobacct={}

      # Initialize the number of accounting files examined to produce the jobacct hash
      @nacctfiles=1

      # Assume the scheduler is up
      @schedup=true

    end


    #####################################################
    #
    # status
    #
    #####################################################
    def status(jobid)

      begin

        raise WorkflowMgr::SchedulerDown unless @schedup

        # Populate the jobs status table if it is empty
        refresh_jobqueue if @jobqueue.empty?

        # Return the jobqueue record if there is one
        return @jobqueue[jobid] if @jobqueue.has_key?(jobid)

        # If we didn't find the job in the jobqueue, look for it in the accounting records

        # Populate the job accounting log table if it is empty
        refresh_jobacct if @jobacct.empty?

        # Return the jobacct record if there is one
        return @jobacct[jobid] if @jobacct.has_key?(jobid)

        # If we still didn't find the job, look at all accounting files if we haven't already
        if @nacctfiles != 25
          refresh_jobacct(25)
          return @jobacct[jobid] if @jobacct.has_key?(jobid)
        end

        # We didn't find the job, so return an uknown status record
        return { :jobid => jobid, :state => "UNKNOWN", :native_state => "Unknown" }

      rescue WorkflowMgr::SchedulerDown
        @schedup=false
        return { :jobid => jobid, :state => "UNAVAILABLE", :native_state => "Unavailable" }
      end

    end

    #####################################################
    #
    # submit
    #
    #####################################################
    def submit(task)

      # Initialize the submit command
      cmd="bsub"

      # Get the Rocoto installation directory
      rocotodir=File.dirname(File.dirname(File.expand_path(File.dirname(__FILE__))))

      # Add LSF batch system options translated from the generic options specification
      task.attributes.each do |option,value|

        case option
          when :account
            cmd += " -P #{value}"
          when :queue            
            cmd += " -q #{value}"
          when :cores  
            next unless task.attributes[:nodes].nil?          
            cmd += " -n #{value}"
          when :nodes
            # Get largest ppn*tpp to calculate ptile
            # -n is ptile * number of nodes
            ptile=0
            nnodes=0
            task_index=0
            task_geometry="{"
            value.split("+").each { |nodespec|
              resources=nodespec.split(":")
              nnodes+=resources.shift.to_i
              ppn=0
              tpp=1
              resources.each { |resource|
                case resource
                  when /ppn=(\d+)/
                    ppn=$1.to_i
                  when /tpp=(\d+)/
                    tpp=$1.to_i
                end
              }
              procs=ppn*tpp
              ptile=procs if procs > ptile
              task_geometry += "(#{(task_index..task_index+ppn-1).to_a.join(",")})"
              task_index += ppn
            }
            task_geometry+="}"

            # Add the ptile to the command
            cmd += " -R span[ptile=#{ptile}]"

            # Add -n to the command
            cmd += " -n #{nnodes*ptile}"
 
            # Setenv the LSB_PJL_TASK_GEOMETRY to specify task layout
            ENV["LSB_PJL_TASK_GEOMETRY"]=task_geometry
          when :walltime
            hhmm=WorkflowMgr.seconds_to_hhmm(WorkflowMgr.ddhhmmss_to_seconds(value))
            cmd += " -W #{hhmm}"
          when :memory
            units=value[-1,1]
            amount=value[0..-2].to_i
            case units
              when /B|b/
                amount=(amount / 1024.0 / 1024.0).ceil
              when /K|k/
                amount=(amount / 1024.0).ceil
              when /M|m/
                amount=amount.ceil
              when /G|g/
                amount=(amount * 1024.0).ceil
              when /[0-9]/
                amount=(value.to_i / 1024.0 / 1024.0).ceil
            end          
            cmd += " -R rusage[mem=#{amount}]"
          when :stdout
            cmd += " -o #{value}"
          when :stderr
            cmd += " -e #{value}"
          when :join
            cmd += " -o #{value}"           
          when :jobname
            cmd += " -J #{value}"
          when :native
	    cmd += " #{value}"
        end
      end

      # LSF does not have an option to pass environment vars
      # Instead, the vars must be set in the environment before submission
      task.envars.each { |name,env|
        if env.nil?
          ENV[name]=""
        else
          ENV[name]=env
        end
      }

      # Add the command to submit
      cmd += " #{rocotodir}/sbin/lsfwrapper.sh #{task.attributes[:command]}"
      WorkflowMgr.stderr("Submitted #{task.attributes[:name]} using '#{cmd}'",4)

      # Run the submit command
      output=`#{cmd} 2>&1`.chomp

      # Parse the output of the submit command
      if output=~/Job <(\d+)> is submitted to (default )*queue/
        return $1,output
      else
 	return nil,output
      end

    end


    #####################################################
    #
    # delete
    #
    #####################################################
    def delete(jobid)

      qdel=`bkill #{jobid}`      

    end

private

    #####################################################
    #
    # refresh_jobqueue
    #
    #####################################################
    def refresh_jobqueue

      # Initialize an empty hash for job queue records
      @jobqueue={}

      begin

        # run bjobs to obtain the current status of queued jobs
        queued_jobs=""
        errors=""
        exit_status=0
        queued_jobs,errors,exit_status=WorkflowMgr.run4("bjobs -w",30)

        # Raise SchedulerDown if the bjobs failed
        raise WorkflowMgr::SchedulerDown,errors unless exit_status==0

        # Return if the bjobs output is empty
        return if queued_jobs.empty? || queued_jobs=~/^No unfinished job found$/

      rescue Timeout::Error,WorkflowMgr::SchedulerDown
        WorkflowMgr.log("#{$!}")
        WorkflowMgr.stderr("#{$!}",3)
        raise WorkflowMgr::SchedulerDown
      end

      # Parse the output of bjobs, building job status records for each job
      queued_jobs.split(/\n/).each { |s|

        # Skip the header line
	next if s=~/^JOBID/

        # Split the fields of the bjobs output
        jobattributes=s.strip.split(/\s+/)

        # Build a job record from the attributes
	if jobattributes.size == 1
          # This is a continuation of the exec host line, which we don't need
          next
        else
        
          # Initialize an empty job record 
          record={} 

          # Record the fields
          record[:jobid]=jobattributes[0]
          record[:user]=jobattributes[1]
          record[:native_state]=jobattributes[2]
          case jobattributes[2]
            when /^PEND$/
              record[:state]="QUEUED"
            when /^RUN$/
              record[:state]="RUNNING"
            else
              record[:state]="UNKNOWN"   
          end          
          record[:queue]=jobattributes[3]
          record[:jobname]=jobattributes[6]
          record[:cores]=nil
          submit_time=ParseDate.parsedate(jobattributes[-3..-1].join(" "),true)
          if submit_time[0].nil?
            now=Time.now
            submit_time[0]=now.year
            if Time.local(*submit_time) > now
              submit_time[0]=now.year-1
            end
          end
          record[:submit_time]=Time.local(*submit_time).getgm
          record[:start_time]=nil
          record[:priority]=nil

          # Put the job record in the jobqueue
	  @jobqueue[record[:jobid]]=record

        end

      }

    end


    #####################################################
    #
    # refresh_jobacct
    #
    #####################################################
    def refresh_jobacct(nacctfiles=1)

      # Get the username of this process
      username=Etc.getpwuid(Process.uid).name

      # Initialize an empty hash of job records
      @jobacct={}

      begin

        # Run bhist to obtain the current status of queued jobs
        completed_jobs=""
        errors=""
        exit_status=0
        timeout=nacctfiles==1 ? 30 : 90
        completed_jobs,errors,exit_status=WorkflowMgr.run4("bhist -n #{nacctfiles} -l -d -w",timeout)

        # Return if the bhist output is empty
        return if completed_jobs.empty? || completed_jobs=~/^No matching job found$/

        # Raise SchedulerDown if the bhist failed
        raise WorkflowMgr::SchedulerDown,errors unless exit_status==0

      rescue Timeout::Error,WorkflowMgr::SchedulerDown
        WorkflowMgr.log("#{$!}")
        WorkflowMgr.stderr("#{$!}",3)
        raise WorkflowMgr::SchedulerDown
      end

      # Build job records from output of bhist
      completed_jobs.split(/^-{10,}\n$/).each { |s|

        record={}

        # Try to format the record such that it is easier to parse
        recordstring=s.strip
        recordstring.gsub!(/\n\s{3,}/,'')
        recordstring.split(/\n+/).each { |event|
          case event.strip
            when /^Job <(\d+)>,( Job Name <([^>]+)>,)* User <([^>]+)>,/
              record[:jobid]=$1
              record[:jobname]=$3
              record[:user]=$4
              record[:native_state]="DONE"
            when /(\w+\s+\w+\s+\d+\s+\d+:\d+:\d+)(\s+\d\d\d\d)*: Submitted from host <[^>]+>, to Queue <([^>]+)>,/
              timestamp=ParseDate.parsedate($1,true)
              if timestamp[0].nil?
                now=Time.now
                timestamp[0]=now.year
                if Time.local(*timestamp) > now
                  timestamp[0]=now.year-1
                end
              end
              record[:submit_time]=Time.local(*timestamp).getgm
              record[:queue]=$2        
            when /(\w+\s+\w+\s+\d+\s+\d+:\d+:\d+)(\s+\d\d\d\d)*: Dispatched to /
              timestamp=ParseDate.parsedate($1,true)
              if timestamp[0].nil?
                now=Time.now
                timestamp[0]=now.year
                if Time.local(*timestamp) > now
                  timestamp[0]=now.year-1
                end
              end
              record[:start_time]=Time.local(*timestamp).getgm
            when /(\w+\s+\w+\s+\d+\s+\d+:\d+:\d+)(\s+\d\d\d\d)*: Done successfully. /
              timestamp=ParseDate.parsedate($1,true)
              if timestamp[0].nil?
                now=Time.now
                timestamp[0]=now.year
                if Time.local(*timestamp) > now
                  timestamp[0]=now.year-1
                end
              end
              record[:end_time]=Time.local(*timestamp).getgm
              record[:exit_status]=0             
              record[:state]="SUCCEEDED"
            when /(\w+\s+\w+\s+\d+\s+\d+:\d+:\d+)(\s+\d\d\d\d)*: Exited with exit code (\d+)/,/(\w+\s+\w+\s+\d+\s+\d+:\d+:\d+)(\s+\d\d\d\d)*: Exited by signal (\d+)/
              timestamp=ParseDate.parsedate($1,true)
              if timestamp[0].nil?
                now=Time.now
                timestamp[0]=now.year
                if Time.local(*timestamp) > now
                  timestamp[0]=now.year-1
                end
              end
              record[:end_time]=Time.local(*timestamp).getgm
              record[:exit_status]=$3.to_i             
              record[:state]="FAILED"
            when /(\w+\s+\w+\s+\d+\s+\d+:\d+:\d+)(\s+\d\d\d\d)*: Exited; job has been forced to exit with exit code (\d+)/
              timestamp=ParseDate.parsedate($1,true)
              if timestamp[0].nil?
                now=Time.now
                timestamp[0]=now.year
                if Time.local(*timestamp) > now
                  timestamp[0]=now.year-1
                end
              end
              record[:end_time]=Time.local(*timestamp).getgm
              record[:exit_status]=$3.to_i             
              record[:state]="FAILED"
            when /(\w+\s+\w+\s+\d+\s+\d+:\d+:\d+)(\s+\d\d\d\d)*: Exited\./
              timestamp=ParseDate.parsedate($1,true)
              if timestamp[0].nil?
                now=Time.now
                timestamp[0]=now.year
                if Time.local(*timestamp) > now
                  timestamp[0]=now.year-1
                end
              end
              record[:end_time]=Time.local(*timestamp).getgm
              record[:exit_status]=255
              record[:state]="FAILED"
            else
          end
        }

        @jobacct[record[:jobid]]=record unless @jobacct.has_key?(record[:jobid])

      }        

      # Update the number of accounting files examined to produce the jobacct hash
      @nacctfiles=nacctfiles

    end

  end

end
