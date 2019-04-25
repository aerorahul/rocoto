###########################################
#
# Module WorkflowMgr
#
##########################################
module WorkflowMgr

  require 'workflowmgr/batchsystem'
  require 'date'

  ##########################################
  #
  # Class SLURMBatchSystem
  #
  ##########################################
  class SLURMBatchSystem < BatchSystem

    require 'etc'
    require 'parsedate'
    require 'libxml'
    require 'workflowmgr/utilities'

    #####################################################
    #
    # initialize
    #
    #####################################################
    def initialize(slurm_root=nil)

      # Initialize an empty hash for job queue records
      @jobqueue={}

      # Initialize an empty hash for job accounting records
      @jobacct={}
      @jobacct_duration=0

      # Assume the scheduler is up
      @schedup=true

    end


    #####################################################
    #
    # statuses
    #
    #####################################################
    def statuses(jobids)

      begin

        raise WorkflowMgr::SchedulerDown unless @schedup

        # Initialize statuses to UNAVAILABLE
        jobStatuses={}
        jobids.each do |jobid|
          jobStatuses[jobid] = { :jobid => jobid, :state => "UNAVAILABLE", :native_state => "Unavailable" }
        end

        jobids.each do |jobid|
          jobStatuses[jobid] = self.status(jobid)
        end

      rescue WorkflowMgr::SchedulerDown
        @schedup=false
      ensure
        return jobStatuses
      end

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

        # Populate the job accounting log table if it is empty
        refresh_jobacct(1) if @jobacct_duration<1

        # Return the jobacct record if there is one
        return @jobacct[jobid] if @jobacct.has_key?(jobid)

        # Now re-populate over a longer history:
        refresh_jobacct(5) if @jobacct_duration<5

        # Return the jobacct record if there is one
        return @jobacct[jobid] if @jobacct.has_key?(jobid)

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
      cmd="sbatch"
      input="#! /bin/sh\n"

      # Add Slurm batch system options translated from the generic options specification
      task.attributes.each do |option,value|
        if value.is_a?(String)
           if value.empty?
             WorkflowMgr.stderr("WARNING: <#{option}> has empty content and is ignored", 1)
             next
           end
        end
        case option
          when :account
            input += "#SBATCH --account #{value}\n"
          when :queue
            input += "#SBATCH --qos #{value}\n"
          when :partition
            input += "#SBATCH --partition #{value.gsub(":",",")}\n"
          when :cores
            # Ignore this attribute if the "nodes" attribute is present
            next unless task.attributes[:nodes].nil?
            input += "#SBATCH --ntasks=#{value}\n"
          when :nodes
            # Rocoto does not currently support Slurm heterogeneous jobs.  However, it does
            # support requests for non-uniform processor geometries.  To accomplish this,
            # Rocoto will use sbatch to submit a job with the smallest uniform resource
            # request that can accommodate the non-uniform request.  It is up to the user to
            # use the appropriate tools to manipulate the host file and use the appropriate
            # MPI launcher command to specify the desired processor layout for the executable
            #  in the job script.

            # Get the total nodes and max ppn requested
            maxppn=1
            nnodes=0
            nodespecs=value.split("+")
            nodespecs.each { |nodespec|
              resources=nodespec.split(":")
              nnodes+=resources.shift.to_i
              ppn=0
              resources.each { |resource|
                case resource
                  when /ppn=(\d+)/
                    ppn=$1.to_i
                  when /tpp=(\d+)/
                    tpp=$1.to_i
                end
              }
              maxppn=ppn if ppn > maxppn
            }

            # Request total number of nodes
            input += "#SBATCH --nodes=#{nnodes}-#{nnodes}\n"

            # Request max tasks per node
            input += "#SBATCH --tasks-per-node=#{maxppn}\n"

            # Print a warning if multiple nodespecs are specified
            if nodespecs.size > 1
              WorkflowMgr.stderr("WARNING: Rocoto does not support Slurm's heterogeneous job feature.  However, Rocoto", 1)
              WorkflowMgr.stderr("WARNING: does support Slurm requests for non-unifortm task geometries.  It does this by", 1)
              WorkflowMgr.stderr("WARNING: converting non-uniform requests into the smallest uniform task geometry", 1)
              WorkflowMgr.stderr("WARNING: request that can accommodate the non-uniform one during batch job submission.", 1)
              WorkflowMgr.stderr("WARNING: It is up to the user to use the -m option of the srun command, or other", 1)
              WorkflowMgr.stderr("WARNING: appropriate tools, in the job script to launch executables with an arbitrary", 1)
              WorkflowMgr.stderr("WARNING: distribution of tasks.", 1)
              WorkflowMgr.stderr("WARNING: Please see https://slurm.schedmd.com/faq.html#arbitrary for details", 1)
              WorkflowMgr.stderr("WARNING: Rocoto has automatically converted '#{value}' to '#{nnodes}:ppn=#{maxppn}' for this job", 1)
              WorkflowMgr.stderr("WARNING: to facilitate the desired arbitrary task distribution.  Use", 1)
              WorkflowMgr.stderr("WARNING: <nodes>#{nnodes}:ppn=#{maxppn}</nodes> in your workflow to eliminate this warning message.", 1)
            end

          when :walltime
            # Make sure format is dd-hh:mm:ss if days are included
            input += "#SBATCH -t #{value.sub(/^(\d+):(\d+:\d+:\d+)$/,'\1-\2')}\n"
          when :memory
            m=/^([\.\d]+)([\D]*)$/.match(value)
            amount=m[1].to_f
            units=m[2]
            case units
              when /^B|b/
                amount=(amount / 1024.0 / 1024.0).ceil
              when /^K|k/
              amount=(amount / 1024.0).ceil
              when /^M|m/
                amount=amount.ceil
              when /^G|g/
                amount=(amount * 1024.0).ceil
              when nil
              amount=(amount / 1024.0 / 1024.0).ceil
            end
            if amount > 0
              input += "#SBATCH --mem=#{amount}\n"
            end
          when :stdout
            input += "#SBATCH -o #{value}\n"
          when :stderr
            input += "#SBATCH -e #{value}\n"
          when :join
            input += "#SBATCH -o #{value}\n"
          when :jobname
            input += "#SBATCH --job-name #{value}\n"
        end
      end

      task.each_native do |value|
        input += "#SBATCH #{value}\n"
      end

      # Add export commands to pass environment vars to the job
      unless task.envars.empty?
        varinput=''
        task.envars.each { |name,env|
          varinput += "export #{name}='#{env}'\n"
        }
        input += varinput
      end

      # Add the command to execute
      input += task.attributes[:command]

      # Generate the execution script that will be submitted
      tf=Tempfile.new('sbatch.in')
      tf.write(input)
      tf.flush()

      WorkflowMgr.stderr("Submitting #{task.attributes[:name]} using #{cmd} < #{tf.path} with input\n{{\n#{input}\n}}",4)

      # Run the submit command
      output=`#{cmd} < #{tf.path} 2>&1`.chomp()

      # Parse the output of the submit command
      if output=~/^Submitted batch job (\d+)/
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

      qdel=`scancel #{jobid}`

    end


private

    #####################################################
    #
    # refresh_jobqueue
    #
    #####################################################
    #####################################################
    #
    # refresh_jobqueue
    #
    #####################################################
    def refresh_jobqueue

      begin

        # Get the username of this process
        username=Etc.getpwuid(Process.uid).name

        # Run qstat to obtain the current status of queued jobs
        queued_jobs=""
        errors=""
        exit_status=0
        queued_jobs,errors,exit_status=WorkflowMgr.run4("squeue -u #{username} -t all -O jobid:40,username:40,numcpus:10,partition:20,submittime:30,starttime:30,endtime:30,priority:30,exit_code:10,state:30,name:200",45)

        # Raise SchedulerDown if the command failed
        raise WorkflowMgr::SchedulerDown,errors unless exit_status==0

        # Return if the output is empty
        return if queued_jobs.empty?

      rescue Timeout::Error,WorkflowMgr::SchedulerDown
        WorkflowMgr.log("#{$!}")
        WorkflowMgr.stderr("#{$!}",3)
        raise WorkflowMgr::SchedulerDown
      end

      # Make sure queued_jobs is properly encoded
      if String.method_defined? :encode
        queued_jobs = queued_jobs.encode('UTF-8', 'binary', {:invalid => :replace, :undef => :replace, :replace => ''})
      end

      # For each job, find the various attributes and create a job record
      queued_jobs.split("\n").each { |job|

        next if job[0..4]=='JOBID' # skip heading

        # Initialize an empty job record
        record={}

        # Extract job id
        record[:jobid]=job[0..39].strip

        # Extract job name
        record[:jobname]=job[270..job.length].strip

        # Extract job owner
        record[:user]=job[40..79].strip

        # Extract core count
        record[:cores]=job[80..89].strip

        # Extract the partition
        record[:queue]=job[90..109].strip

        # Extract the submit time
        record[:submit_time]=Time.local(*job[110..139].strip.split(/[-:T]/)).getgm

        # Extract the start time
        record[:start_time]=Time.local(*job[140..169].strip.split(/[-:T]/)).getgm

        # Extract the end time
        record[:end_time]=Time.local(*job[170..199].strip.split(/[-:T]/)).getgm

        # Extract the priority
        record[:priority]=job[200..229].strip

        # Extract the exit status
        code_signal=job[230..239].strip
        if code_signal=~ /:/

          code,signal=core_signal.split(":").collect {|i| i.to_i}
          if code==0
            record[:exit_status]=signal
          else
            record[:exit_status]=code
          end
        else
          record[:exit_status]=code_signal
        end

        # Extract job state
        case job[240..269].strip
          when /^(CONFIGURING|PENDING|SUSPENDED|RESV_DEL_HOLD|REQUEUE_FED|REQUEUE_HOLD|REQUEUED|SPECIAL_EXIT|SUSPENDED)$/
            record[:state]="QUEUED"
          when /^(RUNNING|COMPLETING|RESIZING|SIGNALING|STAGE_OUT|STOPPED)$/
            record[:state]="RUNNING"
          when /^(CANCELLED|FAILED|NODE_FAIL|PREEMPTED|TIMEOUT|BOOT_FAIL|DEADLINE|OUT_OF_MEMORY|REVOKED)$/
            record[:state]="FAILED"
            record[:exit_status]=255 if record[:exit_status]==0 # Override exit status of 0 for "failed" jobs
          when /^COMPLETED$/
            if record[:exit_status]==0
              record[:state]="SUCCEEDED"
            else
              record[:state]="FAILED"
            end
          else
            record[:state]="UNKNOWN"
        end
        record[:native_state]=job[240..269].strip
        # Add record to job queue
        @jobqueue[record[:jobid]]=record
        WorkflowMgr.stderr("String [[#{job}]] becomes record #{record}",1)

      }  #  queued_jobs.find

    end  # job_queue


    #####################################################
    #
    # refresh_jobacct
    #
    #####################################################
    def refresh_jobacct(delta_days)

      @jobacct_duration=delta_days

      begin

        # Get the username of this process
        username=Etc.getpwuid(Process.uid).name

        # Run qstat to obtain the current status of queued jobs
        completed_jobs=""
        errors=""
        exit_status=0
        mmddyy=(DateTime.now-delta_days).strftime('%m%d%y')
        cmd="sacct -S #{mmddyy} -L -o jobid,user%30,jobname%30,partition%20,priority,submit,start,end,ncpus,exitcode,state%12 -P"
        completed_jobs,errors,exit_status=WorkflowMgr.run4(cmd,45)

        return if errors=~/SLURM accounting storage is disabled/

        # Raise SchedulerDown if the command failed
        raise WorkflowMgr::SchedulerDown,errors unless exit_status==0

        # Return if the output is empty
        return if completed_jobs.empty?

      rescue Timeout::Error,WorkflowMgr::SchedulerDown
        WorkflowMgr.log("#{$!}")
        WorkflowMgr.stderr("#{$!}",3)
        raise WorkflowMgr::SchedulerDown
      end

      # For each job, find the various attributes and create a job record
      completed_jobs.split("\n").each { |job|

        # Initialize an empty job record
        record={}

        # Look at all the attributes for this job and build the record
        jobfields=job.split("|")

        # Skip records for other users
        next unless jobfields[1] =~/^\s*#{username}$/

        # Extract job id
        record[:jobid]=jobfields[0]

        # Extract job name
        record[:jobname]=jobfields[2]

        # Extract job owner
        record[:user]=jobfields[1].split("(").first

        # Extract core count
        record[:cores]=jobfields[8].to_i

        # Extract the partition
        record[:queue]=jobfields[3]

        # Extract the submit time
        record[:submit_time]=Time.local(*jobfields[5].split(/[-:T]/)).getgm

        # Extract the start time
        record[:start_time]=Time.local(*jobfields[6].split(/[-:T]/)).getgm

        # Extract the end time
        record[:end_time]=Time.local(*jobfields[7].split(/[-:T]/)).getgm

        # Extract the priority
        record[:priority]=jobfields[4]

        # Extract the exit status
        code,signal=jobfields[9].split(":").collect {|i| i.to_i}
        if code==0
          record[:exit_status]=signal
        else
          record[:exit_status]=code
        end

        # Extract job state
        case jobfields[10]
          when /^CONFIGURING$/,/^PENDING$/,/^SUSPENDED$/,/^REQUEUED$/
            record[:state]="QUEUED"
          when /^RUNNING$/,/^COMPLETING$/
            record[:state]="RUNNING"
          when /^CANCELLED$/,/^FAILED$/,/^NODE_FAIL$/,/^PREEMPTED$/,/^TIMEOUT$/,/^OUT_OF_MEMORY$/,/^BOOT_FAIL$/,/^DEADLINE$/
            record[:state]="FAILED"
            record[:exit_status]=255 if record[:exit_status]==0 # Override exit status of 0 for "failed" jobs
          when /^COMPLETED$/
            if record[:exit_status]==0
              record[:state]="SUCCEEDED"
            else
              record[:state]="FAILED"
            end
          else
            record[:state]="UNKNOWN"
        end
        record[:native_state]=jobfields[10]

        # Add record to job queue
        @jobacct[record[:jobid]]=record

      }  #  completed_jobs.find

    end  # job_acct

  end  # class

end  # module
