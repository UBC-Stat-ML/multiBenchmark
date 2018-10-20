Usage
-----

Requires Java 8, UNIX, and git.

```
./nextflow run run.nf -resume
```


Adding a Blang model
--------------------

- Go to directory ``model``. Look at one example in there and use as reference. Create a new sub-directory using the naming convention ``[model-name].model``
- Put the ``.bl`` in it
- Add a file ``blangArguments.txt`` containing model-specific arguments
- Add a directory called ``datasets/[name-of-dataset].dataset``
- If it's not too big, add the data in there. Otherwise should set up a setup script infrastructure to run a download script in all dataset directory if present
- Add ``blangArguments.txt`` for dataset-specific arguments.


Adding a Blang sampler configuration
------------------------------------

Just add a line in ``samplers/blang.samplers.txt`` for the arguments for that configuration. Each line will be ran with each dataset. 


Adding a pyMC or other models
-----------------------------

TODO!