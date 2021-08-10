#!/bin/bash

:'************************************************
 Copyright (c) 2019 St.Jude Children Research Hospital to present
 All right reserved
 Author: Shahinur Alam
 Email:salam@stjude.org
 **************************************************
This script is used to stitch 4D (3D+time seriese) images for Cell & Molecular Biology
Department. The department uses a commercial software (yearly cost $4,000) to do 
this task which takes weeks to finish stitching for a single dataset and image stitching
quality is not good. Moreover, he has to do lots of task manually. To resolve those issues,
I have written this script which utilize opensource stitching algorithms to 
eliminate the cost and HPC to optimize the time consumptions. 

Remark:This process has reduced the image stitching time from 2 weeks to 5 hours 
and removed manual interventions 

This script co-ordinate with other programs to perform following tasks
 ================================================================
1. Reads each time points which has 2D tile/images and makes 3D tiles
2. Runs opensource algorithms to stitch each time point images 
3. Combines all time points 
4. Combines all channels  
 
 Input: time seriese 2D tiles/images
 Output: stitched 4D movie
 
 Used tools/packages:
 1. Stitching algorithms: BigStitcher
 2. macros:fiji
 3. singularity container: python codes are in container
 4. parser: jq to parse json file from which this scripts receives  input parameters
 5. BSUB to run jobs in HPC
 
 How to run: ./stitch_image.sh cofig.json
 
'
#***********************************************************************************
#this function is used to keep current process in sleep in two cases:
# 1. if batch is full before submitting next job
# 2. to wait for all jobs to be finished at end of each stages
wait_to_finish_job()
{
#batch size or 1 dependening on stages
 batch_size=$1
 #which job to check in HPC such as 'stitch' or 'img_movie'
 job_type=$2
 
 #start loop to wait  
  while true 
    do
    	#get number of submitted jobs running in HPC
    	num_running_job=`bjobs | grep $job_type | wc -l`
    	#if number of running job is less than batch size or zero exit from loop
    	if [ $num_running_job -lt $batch_size ]; then 
    		break
    	else 
    		sleep 30
    	fi
    done		
}

#receives parameters value from the input JSON file
#absolute path of the data locations
input_folder=`cat $1 | jq -r '.input_folder'`
#absolute path where output will be stored
output_folder=`cat $1 | jq -r '.outputfile'`



#make sure input and output folder exists then read rest of the parameters from JSON
if [ -d "$input_folder" ] &&  [ -d "$output_folder" ]; then
	
	#load some auxiliary module needed to perform the job
	./module.sh	
	input_dir=$input_folder
	output_dir=$output_folder
	#How many time points needs to be stitched
	total_time_point=`cat $1 | jq -r '.frames'`
	#How many tiles in x, y, z
	tilesX=`cat $1 | jq -r '.tilesX'`
	tilesY=`cat $1 | jq -r '.tilesY'`
	tiles_z=`cat $1 | jq -r '.tiles_z'`
	#File pattern to read correct files. Folder may contain auxiliary files other
	# than image tiles
	file_pattern=`cat $1 | jq -r '.file_pattern'`
	#Grid Layout
	grid_type=`cat $1 | jq -r '.grid_type'`
	#Amount of overlap in x, y, z for stitching
	overlap_x=`cat $1 | jq -r '.overlap_x'`
	overlap_y=`cat $1 | jq -r '.overlap_y'`
	overlap_z=`cat $1 | jq -r '.overlap_z'`
	
	#Resolution of images in x, y, z for stitching
	voxel_size_x=`cat $1 | jq -r '.voxel_size_x'`
	voxel_size_y=`cat $1 | jq -r '.voxel_size_y'`
	voxel_size_z=`cat $1 | jq -r '.voxel_size_z'`
	voxel_size_unit=`cat $1 | jq -r '.voxel_size_unit'`
	
	#Stitching methods for BigStitcher
	method=`cat $1 | jq -r '.method'`
	#Downsample factor to make stitching faster
	downsampleBy=`cat $1 | jq -r '.downsampleBy'`
	#available number of channel in volumes
	numChannel=`cat $1 | jq -r '.numChannel'`
	#Channel to use for stitching
	choosen_channel=`cat $1 | jq -r '.choosen_channel'`
	#Threshold for cross-correlation similarity
	min_corr=`cat $1 | jq -r '.min_corr'`
	#Number of Nodes will be used from HPC
	num_of_node=`cat $1 | jq -r '.num_of_node'`
	#how many jobs will be submitted at a time in HPC
	batch_size=`cat $1 | jq -r '.batch_size'`
	#estimated time to finish a job
	walltime=`cat $1 | jq -r '.walltime'`
	
	#whether metadata of physical position of each tiles will be used for stitching
	usemetadata=`cat $1 | jq -r '.usemetadata'`	
	#path where opensource algorithm is located
	imagej_path=`cat $1 | jq -r '.imagej_path'`
	#path where log will be stored
	hpc_log=`cat $1 | jq -r '.hpc_log'`
	#name of the HPC queue where job will be submitted
	queueue=`cat $1 | jq -r '.queueue'`
	
	
	#will create log file to store detail parameters associated with each timepoints
	sequence=`date +%s`
	log_file="${output_dir}/log_${sequence}.txt"
	touch $log_file
	
	#creates some temporary folders to organize process
	basePath=$input_dir
	output_save=$output_dir/final_output/
	output_save_tmp=$output_dir/final_output
	logfile_tmp=$output_dir/log/
	timepoint_ctr=1
	timepoint_act=0
	mkdir $output_dir/final_output
	mkdir $output_dir/log/
	echo "creating folder" >$log_file
	touch $output_dir/log/cmd.sh
	
	#start submitting jobs
	num_running_job=0
	
	####################################Processsing each time points#######################
	#iterate through all time point/folders and submit job in a batch 
	#so that HPC is not over burdened
	for dir in $input_dir/*; do
		    	#pick the directory name from absolute path
				name=`basename $dir`
				filename=$name
				
				#create log file for each timepoint. 
				log_file_tp="${logfile_tmp}log_${name}.txt"
				touch $log_file_tp
				
				#dump status in log file
				echo "Creating subprocess for $name" >>$log_file
				timepoint_act=`expr $timepoint_act + 1`
				#create command file to submit job in HPC
				#it calls fiji macro to do actual job
				echo "${imagej_path}/Fiji.app/ImageJ-linux64 --ij2 --headless --console -macro ${imagej_path}/Fiji.app/bigStitch3D.ijm \"${basePath}/${name}/##${tilesX}##${tilesY}##${tiles_z}##${file_pattern}##${grid_type}##${overlap_x}##${overlap_y}##${overlap_z}##${voxel_size_x}##${voxel_size_y}##${voxel_size_z}##${voxel_size_unit}##${method}##${output_save_tmp}##${downsampleBy}##${filename}##${choosen_channel}##${min_corr}##${usemetadata}\" > $log_file_tp" > $output_dir/log/cmd.sh
				#submit job in HPC. resubmit jobs if any error happens or wall time exceeded
				bsub -Q "all ~0 ~128 ~130" -W ${walltime} -q ${queueue} -P cbi_img_stitch -J stitch -R "rusage[mem=3000]" -R "span[hosts=1]" -n $num_of_node -o ${hpc_log}/out.txt -e ${hpc_log}/error.txt < ${output_dir}/log/cmd.sh
				
				#sleep for a while before checking job status
				sleep 2
				
				# if number of job submitted is greater than batch size go sleep and
				#wait for finishing some jobs to deal with HPC resources 
				#call the wait function to check batch is not full
				wait_to_finish_job $batch_size stitch
			    
			#if do not want to process all time points will stop from here.
			if [ $timepoint_act -eq $total_time_point ]; then
				break
			fi					
	done
	
	# if all jobs are submitted wait for the last jobs to finish
	sleep 30
	#call the wait function to check all time points has been processed
	wait_to_finish_job 1 stitch
	echo "finished all timepoint processing " >> $log_file
	echo "start making movie" >> $log_file
	
	
	###############################Combine time points###########################
	# combine all time points to create a 4D volumes/movies
	#run on a queue that has huge memory
	queueue="priority"
	#number of node to use for this job
	num_of_node=8
	#create command
	echo "#!/bin/bash" > $output_dir/log/cmd.sh
	echo "export SINGULARITY_NOHTTPS=True" >> $output_dir/log/cmd.sh
	echo "ulimit -c 0" >> $output_dir/log/cmd.sh
	#Run singularity container that has defined process for combining all time point
	#basically singularity container invokes python program and shell commands
	echo "/usr/bin/singularity run --bind ${output_save} ${hpc_log}/imagestitching.simg ${output_save}" >> $output_dir/log/cmd.sh
	#submit the job to create movie
	bsub -Q "all ~0 ~128 ~130" -W 00:40 -q ${queueue} -P cbi_img_stitch -J img_movie -R "rusage[mem=2000]" -R "span[hosts=1]" -n $num_of_node -o ${hpc_log}/out.txt -e ${hpc_log}/error.txt < ${output_dir}/log/cmd.sh
	
	#wait untill job is finished
	sleep 30
	wait_to_finish_job 1 img_movie
	
	################################Create Composit from all channels#############
	#adjust sizes to create composite
	total_time_point=$timepoint_act
	#Final stitch to make composite from multiple channel
	slices=`cat "${output_save}tifinfo.txt"`
	echo "Number of slices: ${slices}">> $log_file
	#remove temporary file
	rm "${output_save}tifinfo.txt"
	stitched_tp=`cat "${output_save}stitched_tp.txt"`
	echo "Number of Stitched time point: ${stitched_tp}">> $log_file
	#remove temporary file
	rm "${output_save}stitched_tp.txt"
	#list if there is any time points that has not stitched or failed
	missing_tp=`expr ${total_time_point} - ${stitched_tp}`
	if [ ${stitched_tp} -ne ${total_time_point} ]; then
		echo "Number of timepoint failed to stitch: ${missing_tp}">> $log_file
		total_time_point=${stitched_tp}
	fi
	
	output_dir=$output_dir
	input_dir=$output_save
	
	#output movie file name
	name="Stiched_movie"
	#output composit order
	order="xyzct"
	#output composit type
	composite_type="Color"
	composite_name="Stiched_movie_composite"
	
	#edit fiji config file so that it can allocate large memory 
	conf_file="${imagej_path}/Fiji.app"
	mv ${conf_file}/ImageJ.cfg ${conf_file}/ImageJ_old.cfg
    touch ${conf_file}/ImageJ.cfg
    echo "jre/bin/java" > ${conf_file}/ImageJ.cfg
    #update JVM parameters
    echo "-Xmx290160m -cp ij.jar ij.ImageJ" >> ${conf_file}/ImageJ.cfg		
	
	#submit job with large number of node and memory since volume > 3 00GB
	num_of_node=20
	
	file_name=`ls ${input_dir} | head -1`		
	echo "${imagej_path}/Fiji.app/ImageJ-linux64 --ij2 --headless --console -macro ${imagej_path}/Fiji.app/merge_channel.ijm \"${input_dir}##${file_name}##${output_dir}##${order}##${numChannel}##${slices}##${total_time_point}##${name}##${composite_type}\" >> $log_file" > $output_dir/log/cmd.sh
	#submit the job with large waltime
	bsub -Q "all ~0 ~128 ~130" -W 01:40  -q ${queueue} -P cbi_img_composite -J img_movie -R "rusage[mem=3000]" -R "span[hosts=1]" -n ${total_time_point} -o ${hpc_log}/out.txt -e ${hpc_log}/error.txt < ${output_dir}/log/cmd.sh
	
	composite_type="Composite"
	
	sleep 30
	wait_to_finish_job 1 img_movie
	
	#revert the changes made in fiji config file
	mv ${conf_file}/ImageJ_old.cfg ${conf_file}/ImageJ.cfg
	echo "........Stitching is done..............."

else 
	echo "Input or Output file does not exist!"
fi

