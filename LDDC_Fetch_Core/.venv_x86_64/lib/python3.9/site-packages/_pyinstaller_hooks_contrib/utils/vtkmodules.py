import os

# This list of dependencies was obtained via analysis based on code in `vtkmodules/generate_pyi.py` and augmented with
# missing entries until all tests from `test_vtkmodules` pass. Instead of a pre-computed list, we could dynamically
# analyze each module when the hook is executed; however, such approach would be slower, and would also not account
# for all dependencies that had to be added manually.
#
# NOTE: `vtkmodules.vtkCommonCore` is a dependency of every module, so do not list it here. Modules with no additional
# dependencies are also not listed.
_module_dependencies = {
    'vtkmodules.vtkAcceleratorsVTKmDataModel': [
        'vtkmodules.vtkAcceleratorsVTKmCore',
        'vtkmodules.vtkCommonDataModel',
    ],
    'vtkmodules.vtkAcceleratorsVTKmFilters': [
        'vtkmodules.vtkAcceleratorsVTKmCore',
        'vtkmodules.vtkAcceleratorsVTKmDataModel',
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersCore',
        'vtkmodules.vtkFiltersGeneral',
        'vtkmodules.vtkFiltersGeometry',
        'vtkmodules.vtkImagingCore',
    ],
    'vtkmodules.vtkChartsCore': [
        'vtkmodules.vtkRenderingContext2D',
        'vtkmodules.vtkFiltersGeneral',
    ],
    'vtkmodules.vtkCommonColor': [
        'vtkmodules.vtkCommonDataModel',
    ],
    'vtkmodules.vtkCommonComputationalGeometry': [
        'vtkmodules.vtkCommonDataModel',
    ],
    'vtkmodules.vtkCommonDataModel': [
        'vtkmodules.vtkCommonMath',
        'vtkmodules.vtkCommonTransforms',
        'vtkmodules.util.data_model',
    ],
    'vtkmodules.vtkCommonExecutionModel': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.util.execution_model',
    ],
    'vtkmodules.vtkCommonMisc': [
        'vtkmodules.vtkCommonMath',
    ],
    'vtkmodules.vtkCommonTransforms': [
        'vtkmodules.vtkCommonMath',
    ],
    'vtkmodules.vtkDomainsChemistry': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOLegacy',
        'vtkmodules.vtkIOXMLParser',
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkDomainsChemistryOpenGL2': [
        'vtkmodules.vtkDomainsChemistry',
        'vtkmodules.vtkRenderingOpenGL2',
    ],
    'vtkmodules.vtkFiltersAMR': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersCellGrid': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersCore': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkCommonMisc',
    ],
    'vtkmodules.vtkFiltersExtraction': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersGeneral',
    ],
    'vtkmodules.vtkFiltersFlowPaths': [
        'vtkmodules.vtkCommonComputationalGeometry',
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkCommonMath',
    ],
    'vtkmodules.vtkFiltersGeneral': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersCore',
    ],
    'vtkmodules.vtkFiltersGeneric': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersGeometry': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersGeometryPreview': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersHybrid': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkCommonTransforms',
        'vtkmodules.vtkFiltersGeometry',
    ],
    'vtkmodules.vtkFiltersHyperTree': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersCore',
        'vtkmodules.vtkFiltersGeneral',
    ],
    'vtkmodules.vtkFiltersImaging': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersStatistics',
    ],
    'vtkmodules.vtkFiltersModeling': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersGeneral',
    ],
    'vtkmodules.vtkFiltersParallel': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersCore',
        'vtkmodules.vtkFiltersExtraction',
        'vtkmodules.vtkFiltersGeneral',
        'vtkmodules.vtkFiltersGeometry',
        'vtkmodules.vtkFiltersHybrid',
        'vtkmodules.vtkFiltersHyperTree',
        'vtkmodules.vtkFiltersModeling',
        'vtkmodules.vtkFiltersSources',
        'vtkmodules.vtkFiltersTexture',
    ],
    'vtkmodules.vtkFiltersParallelDIY2': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersCore',
        'vtkmodules.vtkFiltersParallel',
    ],
    'vtkmodules.vtkFiltersParallelImaging': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersImaging',
        'vtkmodules.vtkFiltersParallel',
        'vtkmodules.vtkImagingCore',
    ],
    'vtkmodules.vtkFiltersParallelStatistics': [
        'vtkmodules.vtkFiltersStatistics',
    ],
    'vtkmodules.vtkFiltersPoints': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersModeling',
    ],
    'vtkmodules.vtkFiltersProgrammable': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersPython': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersReduction': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersSMP': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkFiltersCore',
        'vtkmodules.vtkFiltersGeneral',
    ],
    'vtkmodules.vtkFiltersSelection': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersSources': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersStatistics': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersTemporal': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersCore',
    ],
    'vtkmodules.vtkFiltersTensor': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersTexture': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersTopology': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkFiltersVerdict': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkGeovisCore': [
        'vtkmodules.vtkCommonTransforms',
    ],
    'vtkmodules.vtkIOAMR': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOAsynchronous': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCore',
        'vtkmodules.vtkIOImage',
        'vtkmodules.vtkIOXML',
    ],
    'vtkmodules.vtkIOAvmesh': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCore',
    ],
    'vtkmodules.vtkIOCGNSReader': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOCONVERGECFD': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOCellGrid': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersCellGrid',
        'vtkmodules.vtkIOCore',
    ],
    'vtkmodules.vtkIOCesium3DTiles': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCore',
    ],
    'vtkmodules.vtkIOChemistry': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCore',
    ],
    'vtkmodules.vtkIOCityGML': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOCore': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOERF': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOEnSight': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOEngys': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOExodus': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCore',
        'vtkmodules.vtkIOXMLParser',
    ],
    'vtkmodules.vtkIOExport': [
        'vtkmodules.vtkIOCore',
        'vtkmodules.vtkIOImage',
        'vtkmodules.vtkIOXML',
        'vtkmodules.vtkRenderingContext2D',
        'vtkmodules.vtkRenderingCore',
        'vtkmodules.vtkRenderingFreeType',
        'vtkmodules.vtkRenderingVtkJS',
    ],
    'vtkmodules.vtkIOExportGL2PS': [
        'vtkmodules.vtkIOExport',
        'vtkmodules.vtkRenderingGL2PSOpenGL2',
    ],
    'vtkmodules.vtkIOExportPDF': [
        'vtkmodules.vtkIOExport',
        'vtkmodules.vtkRenderingContext2D',
    ],
    'vtkmodules.vtkIOFDS': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOFLUENTCFF': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOGeoJSON': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCore',
    ],
    'vtkmodules.vtkIOGeometry': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCore',
        'vtkmodules.vtkIOLegacy',
    ],
    'vtkmodules.vtkIOH5Rage': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOH5part': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOHDF': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCore',
    ],
    'vtkmodules.vtkIOIOSS': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersCellGrid',
        'vtkmodules.vtkIOCore',
    ],
    'vtkmodules.vtkIOImport': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCore',
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkIOImage': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkImagingCore',
    ],
    'vtkmodules.vtkIOInfovis': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOLegacy',
        'vtkmodules.vtkIOXML',
    ],
    'vtkmodules.vtkIOLANLX3D': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOLSDyna': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOXMLParser',
    ],
    'vtkmodules.vtkIOLegacy': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCellGrid',
        'vtkmodules.vtkIOCore',
    ],
    'vtkmodules.vtkIOMINC': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCore',
        'vtkmodules.vtkIOImage',
    ],
    'vtkmodules.vtkIOMotionFX': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOMovie': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIONetCDF': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCore',
    ],
    'vtkmodules.vtkIOOMF': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOOggTheora': [
        'vtkmodules.vtkIOMovie',
    ],
    'vtkmodules.vtkIOPIO': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOPLY': [
        'vtkmodules.vtkIOCore',
    ],
    'vtkmodules.vtkIOParallel': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCore',
        'vtkmodules.vtkIOGeometry',
        'vtkmodules.vtkIOImage',
        'vtkmodules.vtkIOLegacy',
    ],
    'vtkmodules.vtkIOParallelExodus': [
        'vtkmodules.vtkIOExodus',
    ],
    'vtkmodules.vtkIOParallelLSDyna': [
        'vtkmodules.vtkIOLSDyna',
    ],
    'vtkmodules.vtkIOParallelXML': [
        'vtkmodules.vtkIOXML',
    ],
    'vtkmodules.vtkIOSQL': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOCore',
    ],
    'vtkmodules.vtkIOSegY': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOImage',
    ],
    'vtkmodules.vtkIOTRUCHAS': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOTecplotTable': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOVPIC': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOVeraOut': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOVideo': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkIOXML': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOXMLParser',
    ],
    'vtkmodules.vtkIOXMLParser': [
        'vtkmodules.vtkCommonDataModel',
    ],
    'vtkmodules.vtkIOXdmf2': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkIOLegacy',
    ],
    'vtkmodules.vtkImagingColor': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkImagingCore',
    ],
    'vtkmodules.vtkImagingCore': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkImagingFourier': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkImagingCore',
    ],
    'vtkmodules.vtkImagingGeneral': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkImagingCore',
    ],
    'vtkmodules.vtkImagingHybrid': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkImagingMath': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkImagingMorphological': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkImagingCore',
        'vtkmodules.vtkImagingGeneral',
    ],
    'vtkmodules.vtkImagingOpenGL2': [
        'vtkmodules.vtkImagingGeneral',
        'vtkmodules.vtkRenderingOpenGL2',
    ],
    'vtkmodules.vtkImagingSources': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkImagingStatistics': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkImagingStencil': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkImagingCore',
    ],
    'vtkmodules.vtkInfovisCore': [
        'vtkmodules.vtkCommonColor',
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkImagingSources',
        'vtkmodules.vtkIOImage',
        'vtkmodules.vtkRenderingFreeType',
    ],
    'vtkmodules.vtkInfovisLayout': [
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkInteractionImage': [
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkInteractionStyle': [
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkInteractionWidgets': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkFiltersGeneral',
        'vtkmodules.vtkFiltersSources',
        'vtkmodules.vtkRenderingContext2D',
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkPythonContext2D': [
        'vtkmodules.vtkRenderingContext2D',
    ],
    'vtkmodules.vtkRenderingAnnotation': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkRenderingCellGrid': [
        'vtkmodules.vtkFiltersCellGrid',
        'vtkmodules.vtkRenderingCore',
        'vtkmodules.vtkRenderingOpenGL2',
    ],
    'vtkmodules.vtkRenderingContext2D': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkRenderingContextOpenGL2': [
        'vtkmodules.vtkRenderingContext2D',
        'vtkmodules.vtkRenderingFreeType',
        'vtkmodules.vtkRenderingOpenGL2',
    ],
    'vtkmodules.vtkRenderingCore': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
    ],
    'vtkmodules.vtkRenderingExternal': [
        'vtkmodules.vtkRenderingCore',
        'vtkmodules.vtkRenderingOpenGL2',
    ],
    'vtkmodules.vtkRenderingFreeType': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkRenderingGridAxes': [
        'vtkmodules.vtkChartsCore',
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkRenderingGL2PSOpenGL2': [
        'vtkmodules.vtkRenderingOpenGL2',
    ],
    'vtkmodules.vtkRenderingHyperTreeGrid': [
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkRenderingImage': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkRenderingLICOpenGL2': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkRenderingCore',
        'vtkmodules.vtkRenderingOpenGL2',
    ],
    'vtkmodules.vtkRenderingLOD': [
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkRenderingLabel': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkRenderingCore',
        'vtkmodules.vtkRenderingFreeType',
    ],
    'vtkmodules.vtkRenderingMatplotlib': [
        'vtkmodules.vtkRenderingFreeType',
    ],
    'vtkmodules.vtkRenderingOpenGL2': [
        'vtkmodules.vtkFiltersGeneral',
        'vtkmodules.vtkIOImage',
        'vtkmodules.vtkRenderingCore',
        'vtkmodules.vtkRenderingHyperTreeGrid',
        'vtkmodules.vtkRenderingUI',
    ],
    'vtkmodules.vtkRenderingParallel': [
        'vtkmodules.vtkRenderingCore',
        'vtkmodules.vtkRenderingOpenGL2',
    ],
    'vtkmodules.vtkRenderingUI': [
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkRenderingVR': [
        'vtkmodules.vtkInteractionStyle',
        'vtkmodules.vtkInteractionWidgets',
        'vtkmodules.vtkIOXMLParser',
        'vtkmodules.vtkRenderingCore',
        'vtkmodules.vtkRenderingOpenGL2',
        'vtkmodules.vtkRenderingVolumeOpenGL2',
        'vtkmodules.vtkRenderingVRModels',
    ],
    'vtkmodules.vtkRenderingVRModels': [
        'vtkmodules.vtkRenderingCore',
        'vtkmodules.vtkRenderingOpenGL2',
    ],
    'vtkmodules.vtkRenderingVolume': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkRenderingVolumeAMR': [
        'vtkmodules.vtkImagingCore',
        'vtkmodules.vtkRenderingVolume',
        'vtkmodules.vtkRenderingVolumeOpenGL2',
    ],
    'vtkmodules.vtkRenderingVolumeOpenGL2': [
        'vtkmodules.vtkImagingCore',
        'vtkmodules.vtkImagingMath',
        'vtkmodules.vtkRenderingOpenGL2',
        'vtkmodules.vtkRenderingVolume',
    ],
    'vtkmodules.vtkRenderingVtkJS': [
        'vtkmodules.vtkRenderingSceneGraph',
    ],
    'vtkmodules.vtkTestingRendering': [
        'vtkmodules.vtkImagingColor',
        'vtkmodules.vtkIOXML',
        'vtkmodules.vtkRenderingCore',
    ],
    'vtkmodules.vtkTestingSerialization': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkSerializationManager',
    ],
    'vtkmodules.vtkViewsContext2D': [
        'vtkmodules.vtkRenderingCore',
        'vtkmodules.vtkViewsCore',
    ],
    'vtkmodules.vtkViewsCore': [
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkInteractionWidgets',
    ],
    'vtkmodules.vtkViewsInfovis': [
        'vtkmodules.vtkCommonDataModel',
        'vtkmodules.vtkCommonExecutionModel',
        'vtkmodules.vtkInteractionStyle',
        'vtkmodules.vtkRenderingContext2D',
        'vtkmodules.vtkViewsCore',
    ],
    'vtkmodules.vtkWebGLExporter': [
        'vtkmodules.vtkIOExport',
    ],
}


def add_vtkmodules_dependencies(hook_file):
    # Find the module underlying this vtkmodules hook: change `/path/to/hook-vtkmodules.blah.py` to `vtkmodules.blah`.
    hook_name, hook_ext = os.path.splitext(os.path.basename(hook_file))
    assert hook_ext.startswith('.py')
    assert hook_name.startswith('hook-')
    module_name = hook_name[5:]

    # Look up the list of hidden imports.
    return ["vtkmodules.vtkCommonCore", *_module_dependencies.get(module_name, [])]
