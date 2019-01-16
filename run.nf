#!/usr/bin/env nextflow

params.nSeeds = 1

seeds = (1..params.nSeeds).collect{it}

deliverableDir = 'deliverables/' + workflow.scriptName.replace('.nf','')

params.datasetFilter = "all"

datasets = Channel.fromPath( 'models/*.model/datasets/*.dataset', type: 'dir' ).filter{ 
  result = params.datasetFilter.equals("all") || it.toString().contains(params.datasetFilter) 
  if (result) println("Queuing model " + it.toString().replaceAll(".*models", ""))
  return result
}
datasets.into {
  blangDatasets
}

samplers = Channel.fromPath('samplers/*.samplers.txt').splitText()

// TODO: add *.model/datasets/*.dataset/setup.sh to generate or download+preprocess stuff into /data

process buildBlang {
  cache true
  input:
    val gitRepoName from 'blangSDK'
    val gitUser from 'UBC-Stat-ML'
    val codeRevision from 'd4996f852f742afd6781110c7bb07337c3c16797'
  output:
    file 'path' into blangPath
  """
  # Note: we cannot use standard template because of the way the blang builds in looks for the repo as template
  set -e
  git clone https://github.com/${gitUser}/${gitRepoName}
  cd ${gitRepoName}
  git reset --hard ${codeRevision}
  ./gradlew installDist
  echo `pwd`/build/install/blang/bin/blang > ../path
  """
}

process runBlang {
  echo false
  input:
    each seed from seeds
    each sampler from samplers
    file 'blangExecPath' from blangPath
    file 'dataset' from blangDatasets
  output:
    file 'results/inference' into blangInference
  """
  set -e
  # get the .model path
  modelDir=\$(dirname \$(dirname \$(readlink dataset)))
  # blang model is prefix of the .bl file
  modelName=`ls \$modelDir | grep .bl | sed 's/.bl//'`
  # full path of blang file
  modelPath=\$modelDir/\$modelName.bl
  # copy it since symlinks not picked up
  cp \$modelPath .
  # copy any other java or xtend files
  if [ -f \$modelDir/*.java ]; then
    cp \$modelDir/*.java .
  fi
  if [ -f \$modelDir/*.xtend ]; then
    cp \$modelDir/*.xtend .
  fi
  # get the package too (assume it appear in first line)
  modelPackage=`head -n 1 \$modelPath | sed 's/package//' | sed 's/ //g' | sed 's/;//'`
  # get global model arguments
  modelArguments=`cat \$modelDir/blangArguments.txt | tr '\n' ' '`
  # get dataset arguments
  datasetArguments=`cat dataset/blangArguments.txt | tr '\n' ' '`
  # run the blang model
  samplerStr=`echo "$sampler" | tr '\n' ' '`
  blangCmd=`cat blangExecPath`
  \$blangCmd \
    --model \${modelPackage}.\${modelName} \
    \$datasetArguments \
    \$modelArguments \
    \$samplerStr \
    --initRandom $seed \
    --engine.random $seed   
  mv results/latest results/inference
  # log some info for easy access later in the pipeline
  datasetName=\$(basename \$(readlink dataset))
  datasetName=`echo \$datasetName | sed 's/.dataset//'`
  echo "\nmodelName\t\$modelName" >> results/inference/arguments.tsv
  echo "datasetName\t\$datasetName" >> results/inference/arguments.tsv
  echo "sampler\t\$samplerStr" >> results/inference/arguments.tsv
  """
}

// TODO: run other baselines, use firstchannel.mix(anotherone, andanother), replacing line below
blangInference.into{ inferenceResults }
inferenceResults.into {
  inferenceResultsForEss
  inferenceResultsForDensityPlots
}

process analysisCode { 
  input:
    val gitRepoName from 'nedry'
    val gitUser from 'alexandrebouchard'
    val codeRevision from '4c6ddf0de0027ad88d73ef6634d1e70cc9f94bfe'
    val snapshotPath from "${System.getProperty('user.home')}/w/nedry"
  output:
    file 'code' into analysisCode
  script:
    template 'buildRepo.sh'
}
analysisCode.into {
  essCode
  aggregateEssCode
  aggregateDensityCode
} 

process computeESS {
  conda 'csvkit'
  input:
    file 'results/inference' from inferenceResultsForEss
    file essCode
  output:
    file 'results' into essResults
  """
  mkdir results/ess
  outputDir=results/ess
  allESSName=ess-all.csv
  echo "ess" >> \$outputDir/\$allESSName
  for sampleFile in results/inference/samples/*.csv; do
    output=\$outputDir/ess-\$(basename \$sampleFile)
    code/bin/ess  \
      --experimentConfigs.saveStandardStreams false \
      --experimentConfigs.managedExecutionFolder false \
      --inputFile \$sampleFile \
      --burnInFraction 0.5 \
      --moment 2 \
      --output \$output
    csvcut -c ess \$output | grep -v ess >> \$outputDir/\$allESSName
  done
  """
}

process aggregateEss {
  input:
    file aggregateEssCode
    file 'exec_*' from essResults.toList()
  output:
    file aggregated
  """
  code/bin/aggregate \
    --experimentConfigs.saveStandardStreams false \
    --experimentConfigs.managedExecutionFolder false \
    --dataPathInEachExecFolder ess/ess-all.csv \
    --keys \
      sampler modelName datasetName engine.random as seed from inference/arguments.tsv, \
      samplingTime_ms from inference/monitoring/runningTimeSummary.tsv
  """
}


process plotEss {
  echo false
  input:
    file aggregated
    env SPARK_HOME from "${System.getProperty('user.home')}/bin/spark-2.1.0-bin-hadoop2.7"
  output:
    file '*.pdf' into essPlots
    file '*.csv'
  publishDir deliverableDir, mode: 'copy', overwrite: true
  afterScript 'rm -r metastore_db; rm derby.log'
  """
  #!/usr/bin/env Rscript
  require("ggplot2")
  library(SparkR, lib.loc = c(file.path(Sys.getenv("SPARK_HOME"), "R", "lib")))
  sparkR.session(master = "local[*]", sparkConfig = list(spark.driver.memory = "4g"))
  
  data <- read.df("$aggregated", "csv", header="true", inferSchema="true")
  data <- collect(data)
  data\$setup <- paste(data\$modelName, data\$datasetName, sep="_")
  write.csv(data, "ess.csv")
  
  # TODO: check they all have same length

  p <- ggplot(data, aes(x = sampler, y = ess, colour = factor(seed))) +
    geom_boxplot() +
    coord_flip() +
    facet_grid(setup ~ ., scales = "free") + # second will be the class of method? or min med max
    theme_bw() + theme(legend.position="none")
  ggsave("ess.pdf", p, width = 10, height = 5, limitsize = FALSE)
  """
}


process aggregateDensity {
  input:
    file aggregateDensityCode
    file 'exec_*' from inferenceResultsForDensityPlots.toList()
  output:
    file 'aggregated' into aggregatedDensity
  """
  code/bin/aggregate \
    --experimentConfigs.saveStandardStreams false \
    --experimentConfigs.managedExecutionFolder false \
    --dataPathInEachExecFolder samples/logDensity.csv \
    --keys \
      sampler modelName datasetName engine.random as seed from arguments.tsv, \
      samplingTime_ms from monitoring/runningTimeSummary.tsv
  """
}


process plotDensity {
  echo false
  input:
    file essPlots // hack to make sure no two spark sessions concurrently
    file 'aggregated' from aggregatedDensity
    env SPARK_HOME from "${System.getProperty('user.home')}/bin/spark-2.1.0-bin-hadoop2.7"
  output:
    file '*.pdf'
  publishDir deliverableDir, mode: 'copy', overwrite: true
  afterScript 'rm -r metastore_db; rm derby.log'
  """
  #!/usr/bin/env Rscript
  require("ggplot2")
  library(SparkR, lib.loc = c(file.path(Sys.getenv("SPARK_HOME"), "R", "lib")))
  sparkR.session(master = "local[*]", sparkConfig = list(spark.driver.memory = "4g"))
  
  data <- read.df("aggregated", "csv", header="true", inferSchema="true")
  data <- collect(data)
  data\$setup <- paste(data\$modelName, data\$datasetName, sep="_")

  # TODO: check they all have same length

  p <- ggplot(data, aes(x = sample, y = value, colour = factor(seed))) +
    geom_line() +
    facet_grid(setup ~ sampler, scales = "free") + # second will be the class of method? or min med max
    theme_bw() + theme(legend.position="none")
  ggsave("traces.pdf", p, width = 10, height = 5, limitsize = FALSE)
  """
}


process summarizePipeline {
  cache false
  output:
      file 'pipeline-info.txt'
  publishDir deliverableDir, mode: 'copy', overwrite: true
  """
  echo 'scriptName: $workflow.scriptName' >> pipeline-info.txt
  echo 'start: $workflow.start' >> pipeline-info.txt
  echo 'runName: $workflow.runName' >> pipeline-info.txt
  echo 'nextflow.version: $workflow.nextflow.version' >> pipeline-info.txt
  """
}