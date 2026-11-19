-- Lmod module file for the containerized RDKit descriptor workload.
--
-- Use (from the repository root):
--   module use "$PWD/modules"        -- add this folder to MODULEPATH
--   module load rdkit-descriptors
--   compute-descriptors --help
--
-- The version (2026.09.2) is the RDKit version inside the image.
-- Loading adds the repository's bin/ folder to PATH and sets
-- RDKIT_DESCRIPTORS_SIF; unloading removes both again.

-- This file is <repo>/modules/rdkit-descriptors/<version>.lua, so the
-- repository root is three folders up. Finding it this way means the
-- module works wherever the repository was cloned.
local root = myFileName():gsub("/modules/rdkit%-descriptors/[^/]+%.lua$", "")
local sif  = pathJoin(root, "container", "rdkit-descriptors.sif")

whatis("Name: rdkit-descriptors")
whatis("Version: " .. myModuleVersion())
whatis("Description: RDKit molecular descriptors for ChEMBL chemreps files, in an Apptainer image")

help([[
RDKit 2026.09.2 descriptor workload, run inside an Apptainer image.

Command:
  compute-descriptors --input FILE --output FILE [--chunk-size N --chunk-index K]

Input and output files must be in a folder the container can see: your home
folder, /tmp and the current folder are mounted by default. For other
folders, set APPTAINER_BIND (for example: export APPTAINER_BIND=/scratch/$USER).

Image: ]] .. sif .. [[


Requires the 'apptainer' command.
]])

-- Only check on load, so 'module avail' and 'module spider' still work
-- before the image has been built.
if mode() == "load" and not isFile(sif) then
    LmodError("Image not found: " .. sif .. "\n" ..
              "Build it first: apptainer build container/rdkit-descriptors.sif container/tool.def")
end

setenv("RDKIT_DESCRIPTORS_SIF", sif)
prepend_path("PATH", pathJoin(root, "bin"))
