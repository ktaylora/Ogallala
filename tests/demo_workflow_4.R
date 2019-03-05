#
# Workflow that generates a basic aquifer saturated thickness raster
# for multiple years of well depth data
#
# Author : kyle.taylor@pljv.org
#

# 2013 is the most recent year that the USGS has published. See:
# https://ne.water.usgs.gov/ogw/hpwlms/data.html
years <- 2013:1995 

# let's use the included base elevation and surface_elevation by default
# we could swap these out for our own if we wanted
base_elevation <- get(
    'base_elevation',
    envir=asNamespace('Ogallala')
  )

surface_elevation <- get(
    'surface_elevation',
    envir=asNamespace('Ogallala')
  )

well_pts <- Ogallala:::unpack_well_point_data(Ogallala:::scrape_well_point_data(years=years))

for(i in 1:length(well_pts)){
  cat("-- processing year:",years[i],"\n")
  well_pts[[i]] <- Ogallala:::calc_saturated_thickness(
    wellPts=well_pts[[i]],
    baseRaster=base_elevation,
    surfaceRaster=surface_elevation,
    convert_to_imperial=T
  )
  well_pts[[i]] <- raster::rasterize(
      x=sp::spTransform(well_pts[[i]], sp::CRS(raster::projection(base_elevation))), 
      y=base_elevation,
      field='saturated_thickness',
      background=0
    ) 
}

well_pts <- raster::stack(well_pts)
  names(well_pts) <- years

potential_thickness <- surface_elevation - base_elevation
  potential_thickness[potential_thickness < 0] <- 0

potential_thickness <- ceiling(Ogallala:::meters_to_feet(potential_thickness))
  potential_thickness[potential_thickness < 1] <- 1

test <- well_pts[[1]] / potential_thickness
  test[ test > 1 ] <- 1