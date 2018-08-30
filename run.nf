#!/usr/bin/env nextflow

deliverableDir = 'deliverables/' + workflow.scriptName.replace('.nf','')

data = file('data')

datasets = Channel.fromPath( 'models/*.model/datasets/*.dataset', type: 'dir' )
datasets.into {
  blangDatasets
}

// TODO: add *.model/datasets/*.dataset/setup.sh to generate or download+preprocess stuff into /data

process runBlang {
  echo false
  input:
    file 'dataset' from blangDatasets
  output:
    file 'results/inference' into blangInference
  """
  # get the .model path
  modelDir=\$(dirname \$(dirname \$(readlink dataset)))
  # blang model is prefix of the .bl file
  modelName=`ls \$modelDir | grep .bl | sed 's/.bl//'`
  # full path of blang file
  modelPath=\$modelDir/\$modelName.bl
  # copy it since symlinks not picked up
  cp \$modelPath .
  # get the package too (assume it appear in first line)
  modelPackage=`head -n 1 \$modelPath | sed 's/package//' | sed 's/ //g' | sed 's/;//'`
  # easy access to data files
  ln -s $data .
  # get global model arguments
  modelArguments=`cat \$modelDir/blangArguments.txt | tr '\n' ' '`
  # get dataset arguments
  datasetArguments=`cat dataset/blangArguments.txt | tr '\n' ' '`
  # run the blang model
  blang \
    --engine PT \
    --model \${modelPackage}.\${modelName} \
    \$datasetArguments \
    \$modelArguments
  mv results/latest results/inference
  # log some info for easy access later in the pipeline
  datasetName=\$(basename \$(readlink dataset))
  datasetName=`echo \$datasetName | sed 's/.dataset//'`
  echo "\nmodelName\t\$modelName" >> results/inference/arguments.tsv
  echo "datasetName\t\$datasetName" >> results/inference/arguments.tsv
  """
}

// TODO: run other baselines, use firstchannel.mix(anotherone, andanother), replacing line below
blangInference.into{ inferenceResults }

process analysisCode { // TODO: add this to the bin/lib folders instead (refactor setup not to erase stuff in lib then)
  input:
    val gitRepoName from 'nedry'
    val gitUser from 'alexandrebouchard'
    val codeRevision from 'cf1a17574f19f22c4caf6878669df921df27c868'
    val snapshotPath from "${System.getProperty('user.home')}/w/nedry"
  output:
    file 'code' into analysisCode
  script:
    template 'buildSnapshot.sh'
}
analysisCode.into {
  essCode
} 

process computeESS {
  input:
    file 'results/inference' from inferenceResults
    file essCode
  """
  mkdir results/ess
  for sampleFile in results/inference/samples/*.csv; do
    code/bin/ess  \
      --experimentConfigs.saveStandardStreams false \
      --experimentConfigs.managedExecutionFolder false \
      --inputFile \$sampleFile \
      --output results/ess/\$(basename \$sampleFile)
  done
  """
}

// aggregate

// plots, tables, and save csv's