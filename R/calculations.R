#' hidden function for feet-> meters
feet_to_meters <- function(x) x*0.3048
#' hidden function for meters -> feet
meters_to_feet <- function(x) x*3.28084
logit <- function(x) round( log( x / (1 - x) ), 2)
#' generate a universal grid at the target resolution (500m) originally specified
#' by V. McGuire and others for their interpolation.
generate_target_raster_grid <- function(s=NULL) {
  extent <- raster::extent(sp::spTransform(s,CRSobj=sp::CRS("+init=epsg:2163")))
  grid <- raster::raster(resolution=500,
                         ext=extent,
                         crs=sp::CRS("+init=epsg:2163"))
  return(grid)
}
#' normalize a vector X so that it's values occur on a 0-to-1 scale. Optionally
#' project the trend to a new maximum using the to= argument. This is useful
#' for rescaling predicted thickness to the known ranges of saturated thickness
#' throughout the HP region [0 to about 1,200 ft] (Weeks and Gutentag, 1981)
min_max_normalize <- function(x, to=1300){
  if(inherits(x,"Raster")){
      min <- cellStats(x,stat='min',na.rm=T)
    range <- diff(cellStats(x,stat=range,na.rm=T))
        x <- (x-min)/range
  } else {
    x <- (x-min(x))/(diff(range(x)))
  }
  if(is.null(to)){
    return(x)
  } else {
    return(x*to)
  }
}
#' normalize a vector x to quantiles. By default (if no quantiles are specified
#' for calculating a range), we will use 1 SD and produce a Z-score equivalent
quantile_normalize <- function(x, quantiles=NULL, to=NULL){
  if(!is.null(quantiles)){
    div <- diff(quantile(
        x,
        na.rm=T,
        p=quantiles
      ))
  } else {
    div <- sd(x,na.rm=T) # scale to 1 SD by default
  }
  x <- (x-mean(x,na.rm=T))/div
  return(x)
}
#' hidden shortcut for gstat's idw interpolator
idw_interpolator <- function(pts,targetRasterGrid=NULL,field="ELEV"){
  pts <- pts[!is.na(pts@data[,field]),] # drop any NA values
  g <- gstat::gstat(id=field,
                    formula = as.formula(paste(field,"~1",sep="")),
                    data=pts)
  return(raster::interpolate(targetRasterGrid, g))
}
#' using ofr98-393, make a contour line to raster product. The units on
#' base elevation are feet (imperial). We are going to change them to
#' meters so they are consistent with surface DEMs from NED.
#' @param two_pass Boolean. Should we do a second pass of IDW interpolation to remove artifacts in
#' base elevation.
#' @param feet_to_meters Boolean. Should we convert feet into meters?
generate_base_elevation_raster <- function(s=NULL,targetRasterGrid=NULL,
                                        two_pass=T, feet_to_meters=T,
                                        mask=F){
  # sanity-check
  names(s) <- toupper(names(s))
  if(sum(grepl(names(s),pattern="ELEV"))==0) stop("no ELEV field found in the s= base countour shapefile provided.")
  if(is.null(targetRasterGrid)){
    cat(" -- using extent data from input Spatial* data to generate a 500m target grid\n")
    targetRasterGrid <- Ogallala:::generate_target_raster_grid(s=s)
  }
  cat(" -- interpolating\n")
  cat(" -- pass one: ")
  grid_pts <- as(s, 'SpatialPointsDataFrame')
  if(feet_to_meters){
    grid_pts$ELEV <- feet_to_meters(grid_pts$ELEV)
  }
  base <- Ogallala:::idw_interpolator(grid_pts, targetRasterGrid)
  # IDW is meant to be used on scattered data. Our contour lines were definately
  # not scattered and this results in localized artifacts in our interpolation
  # we are going to re-sample the raster again and re-do our interpolation
  # to try and smooth over these artifacts
  if(two_pass){
    cat(" -- pass two (resampling to remove artifacts): ")
    resampled <- raster::sampleRandom(base,size=9999,sp=T)
      names(resampled) <- "ELEV"
    base <- Ogallala:::idw_interpolator(resampled, targetRasterGrid)
  }
  if(mask){
    cat(" -- masking\n")
    if(!file.exists(file.path("boundaries/ds543.zip"))){
      scrape_high_plains_aquifer_boundary()
    }
    boundary <- sp::spTransform(unpack_high_plains_aquifer_boundary(),
                                sp::CRS(raster::projection(base)))
    base <- raster::mask(base, boundary)
  }
  return(base)
}
#' Do a burn-in of an input raster and the ofr99-266 dry areas
#' dataset
generate_zero_burnin_surface <- function(r=NULL, width=500){
  # define our default (unweighted) target mask
  target <- r
    values(target) <- 1
  # define our "zero" mask, with some arbitrary wiggle-room
  no_thickness_boundary <- rgeos::gPolygonize(
    Ogallala:::unpack_unsampled_zero_values())
  no_thickness_boundary <- rgeos::gBuffer(no_thickness_boundary,
    byid=F,width=width*2)
  surface <- rgeos::gBuffer(no_thickness_boundary,byid=F,width=0)
    surface$val <- NA
  # not really count controlled -- limited by a null return from gBuffer
  maxCount = 500;
  for(i in 1:maxCount){
    focal <- rgeos::gBuffer(
        no_thickness_boundary, 
        byid=F, 
        width=i*-width
      )
    if(is.null(focal)){
      i = maxCount;
    } else {
      focal$val <- i
      surface <- bind(surface, focal)
    }
  }
  # apply a power function to our linear increment and rasterize
  surface$val <- as.numeric(surface$val)
    surface$val <- 1-((surface$val/max(surface$val,na.rm=T))^(1/2))
      surface$val[is.na(surface$val)] <- 1
  surface <- rasterize(surface,field='val',
    y=target, background=1,progress='text')
  return(r*surface)
}
#' generate a uniform buffer region around the HP aquifer boundary
#' that can be used for downsampling
generate_aquifer_boundary_buffer <- function(boundary=NULL, width=5000){
  buffer <- rgeos::gBuffer(boundary, width=-1, byid=F)
    buffer <- rgeos::gSymdifference(buffer,
      rgeos::gBuffer(boundary, width=-width, byid=F))
  return(buffer)
}
#' downsample well points that occur along the aquifer boundary
downsample_aquifer_boundary <- function(wellPoints=NULL, boundary=NULL, width=3000){
  buffer <- spTransform(Ogallala:::generate_aquifer_boundary_buffer(boundary, width=width),
    CRS(projection(wellPoints)))
  over <- !is.na(as.vector(sp::over(wellPoints, buffer)))
  cat(" -- downsampling",sum(over),
    "points along HP aquifer boundary\n")
  return(wellPoints[!over,])
}
#' download the ofr99-266 dry areas dataset and randomly generate points
#' within the polygon features to use as pseudo-zero sat. thickness data
generate_pseudo_zeros <- function(wellPts=NULL, targetRasterGrid=NULL, size=NULL){
  no_thickness_boundary <- rgeos::gPolygonize(Ogallala:::unpack_unsampled_zero_values())
  if(is.null(size)){
    # do an area-weighted sampling to figure out point sample size
    # appropriate for our point generation
    region_area <- Ogallala:::scrape_high_plains_aquifer_boundary()
       region_area <- Ogallala:::unpack_high_plains_aquifer_boundary(region_area)
    region_area <- rgeos::gArea(region_area[
                     region_area$AQUIFER ==
                       unique(region_area$AQUIFER)[1],])

    no_thickness_area <- rgeos::gArea(no_thickness_boundary)

    size = round( (no_thickness_area/region_area) * nrow(wellPts) )
  }
  if(is.null(targetRasterGrid)){
    targetRasterGrid <- Ogallala:::generateTargetRasterGrid(s=no_thickness_boundary)
  }
  # rasterize our polygon features
  no_thickness_boundary <- raster::rasterize(no_thickness_boundary,
                                             targetRasterGrid)
  # sample stratified
  pts <- sampleStratified(no_thickness_boundary>0, size=size, sp=T)
    pts <- spTransform(pts,CRS(projection(wellPts)))
  # merge with our source wellPts dataset
  t <- wellPts@data[1:nrow(pts),]
    t[,] <- NA
      t$saturated_thickness <- 0
  pts@data <- t
  return(rbind(wellPts,pts))
}
#' calculate saturated thickness for a series of well points and the base elevation of
#' the aquifer (as returned by ogallala::generateBaseElevationRaster())
#' @export
calc_saturated_thickness <- function(wellPts=NULL,baseRaster=NULL,
                                        surfaceRaster=NULL, convert_to_imperial=T){
  # sanity-check our input
  if(is.null(wellPts)) stop("wellPts= needs to be a SpatialPointsDataFrame specifying
                             well point data, as returned by unpackWellPointData()")
  if(is.null(baseRaster)){
    baseRaster = Ogallala::generateBaseElevationRaster(s=wellPts)
  } else if(!inherits(baseRaster,'Raster')){
    stop("baseRaster= argument must be a raster object, as returned by generateBaseElevationRaster()")
  }
  if(is.null(surfaceRaster)){
    surfaceRaster = Ogallala::scrapeNed(s=wellPts)
  } else if(!inherits(surfaceRaster,'Raster')){
    stop("surfaceRaster= argument must be a raster object")
  }
  if(raster::projection(surfaceRaster) != raster::projection(baseRaster)){
    cat(" -- re-gridding surface raster to the resolution of our base raster\n")
    surfaceRaster <- projectRaster(surfaceRaster,
                                   to=baseRaster)
  }
  if(convert_to_imperial){
    wellPts$well_depth_ft <- feet_to_meters(wellPts$well_depth_ft)
    wellPts$lev_va_ft <- feet_to_meters(wellPts$lev_va_ft)
  }
  # extract surface and aquifer base information for our well points
  wellPts$surface_elevation <-
    raster::extract(x=surfaceRaster,
                    y=sp::spTransform(wellPts,sp::CRS(raster::projection(surfaceRaster))),
                    method='bilinear'
                   )
  wellPts$base_elevation <-
    raster::extract(x=baseRaster,
                    y=sp::spTransform(wellPts,sp::CRS(raster::projection(baseRaster))),
                    method='bilinear'
                   )
  # calculate saturated thickness
  depth_to_base <-
         (wellPts$surface_elevation - wellPts$base_elevation)
  wellPts$saturated_thickness <-
    depth_to_base - wellPts$lev_va_ft
  # units are always reported in (imperial) feet of saturated thickness
  wellPts$saturated_thickness <- 
    if(convert_to_imperial) { 
      round(meters_to_feet(wellPts$saturated_thickness),2) 
    } else {
      round(wellPts$saturated_thickness,2)
    }
  # remove any lurking non-sense values
  wellPts <- wellPts[!is.na(wellPts@data$saturated_thickness),]

  # drop points that have negative values for surface-base elevation
  drop <- (wellPts$surface_elevation-wellPts$base_elevation) < 0
  wellPts <- wellPts[!drop,]

  # remove any well that have negative saturated thickness
  wellPts <- wellPts[wellPts@data$saturated_thickness>=0,]

  return(wellPts)
}
#' use a KNN classifier fit to lat/lon to select a neighborhood of points around
#' each well and calculates a summary statistic of your choosing (e.g., mean)
#' @export
knn_point_smoother <- function(pts=NULL, field=NULL, k=4, fun=mean){
  index <- cbind(1:nrow(pts),
             FNN::get.knn(pts@coords, k=k)$nn.index)
  pts@data[,paste(field,"_smoothed",sep="")] <-
    apply(MARGIN=1,matrix(pts@data[as.vector(index),field],ncol=k+1),
          FUN=fun, na.rm=T)
  return(pts)
}
#' testing for a spatially-weighted GLM that attempts to down-weight
#' clustered records and up-weight diffuse records using KNN.
m_knn_weights <- function(pts, order=4, field=NULL, k=5){
  t <- cbind(pts@data[,field], pts@coords, pts$surface_elevation, pts$base_elevation)
    colnames(t) <- c(field,"longitude","latitude","surf_elev","base_elev")
      t <- data.frame(t)
  # determine the covariates we are going to fit for this model
  covs <- paste("poly(",colnames(t)[2:ncol(t)],",", order, ")",sep="")
    covs <- paste(covs,collapse="+")
      formula <- as.formula(paste(field,"~",covs,collapse=""))
  # append our scaled composite NN distances
  t$nn_distances <- round(Ogallala:::quantileNormalize(
    rowMeans(FNN::get.knn(pts@coords, k=k)$nn.dist)))
  t$nn_distances <- t$nn_distances+abs(min(t$nn_distances))
  #t$nn_distances[t$nn_distances<0] <- 0 # spatially clustered
    #t$nn_distances <- t$nn_distances + 1
  t<-na.omit(t)
  m <- glm(formula,data=t,weights=t$nn_distances)
  return(m)
}
#' testing for a standard GLM with polynomial terms on latitude
#' and longitude
m_glm_spatial_trend <- function(pts, order=2, field=NULL){
  t <- cbind(pts@data[,field], pts@coords, pts$surface_elevation, pts$base_elevation)
    colnames(t) <- c(field,"longitude","latitude","surf_elev","base_elev")
      t <- data.frame(t)
  covs <- paste("poly(",colnames(t)[2:ncol(t)],",", order, ")",sep="")
    covs <- paste(covs,collapse="+")
      formula <- as.formula(paste(field,"~",covs,collapse=""))
  return(glm(formula,data=na.omit(t)))
}
m_rf_logistic_trend <- function(pts, fields=c('year')){
    t <- cbind(
      pts@data[,fields], 
      pts@coords, 
      pts$surface_elevation, 
      pts$base_elevation
    )
    colnames(t) <- c(fields,"longitude","latitude","surf_elev","base_elev")
      t <- data.frame(t)
    
    covs <- paste("poly(",colnames(t)[2:ncol(t)],",", order, ")",sep="")
    covs <- paste(covs,collapse="+")
    
    formula <- as.formula(paste(field,"~",covs,collapse=""))
}
#' fit a higher-order GLM to our spatial data and a field of your choice
#' and use it to generate a polynomial trend raster surface of that field
#' @export
calc_polynomial_trend_surface <- function(pts, order=3,
                                   field=NULL, predRaster=NULL){
  # testing : removing default and checking 
  # the performance of a spatially-weighted glm
  #m <- m_knn_weights(pts, order=order, field=field, k=5)
  m <- m_spatial_trend(pts, order=order, field=field)

  # if the user provided a rasterStack for making predictions, let's use it.
  if(!is.null(predRaster)){
    # if we are missing predictors, are they latitude and longitude?
    if(sum(c("longitude","latitude") %in% names(predRaster)) < 2){
      cat(" -- calculating latitude and longitude\n")
      predRaster$latitude  <- raster::init(predRaster,"y")
      predRaster$longitude <- raster::init(predRaster,"x")
    }
    cat(" -- projecting across regional extent:\n")
    polynomial_trend <- raster::predict(predRaster,m,progress='text',type="response")
    return(list(m=m,raster=polynomial_trend))
  }
  # return the model by default
  return(m)
}
#' split an input dataset into training/testing using a user-specified ratio
split_training_testing_datasets <- function(pts=NULL,split=0.2){
  rows <- 1:nrow(pts)
  out_sample  <- sample(rows, size=split*nrow(pts))
  in_sample   <- rows[!rows %in% out_sample]
  return(list(training=pts[in_sample,],testing=pts[out_sample,]))
}
