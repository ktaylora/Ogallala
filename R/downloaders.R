#' subset by grep match
grep_by <- function(x, pattern=NULL){
  x[grepl(x, pattern=pattern)]
}
#' grab all zips by default and parse through what the user requested
parse_hrefs <- function(url=NULL){
  a <- xml2::read_html(url)
    return(as.character(rvest::html_nodes(a,"a")))
}
#' hidden function that grabs the full strings within a set of parantheses
#' in an HTML href.
#' @param pattern optional pattern to filter href links against
parse_url <- function (x = NULL, pattern = NULL)
{
    if (sum(grepl(x, pattern = "\"")) == length(x)) {
      split <- unlist(lapply(strsplit(x, split = "\""), FUN = function(x)
        x[length(x) -1]))
    }
    else if (grepl(x, pattern = "<|>")) {
        split <- unlist(lapply(strsplit(as.character(x), split = ">|<"),
            function(x) x[3]))
    }
    # make sure the vector of files with our reference string
    if(!is.null(pattern)){
      unlist(lapply(split, FUN = function(x) x[which(grepl(x, pattern = pattern))]))
    } else {
      return(split)
    }
}
#' scrape the national elevation dataset (using FedData) to fetch and merge
#' surface elevation DEMs for our region
#' @export
scrape_ned <- function(s=NULL){
  if(dir.exists("RAW")){
    unlink("RAW",recursive=T, force=T)
  }
  if(file.exists("surface_elevation.tif")){
    return(raster::raster("surface_elevation.tif"))
  }
  r <- FedData::get_ned(s, label="regional_elevation_tiles", force.redo=T)
    raster::writeRaster(r,"surface_elevation.tif",progress='text')
  return(r)
}
#' webscrape functionality for the hp aquifer boundary contour provided by USGS.
#' Returns a full pathname to the zipfile containing the boundary (ESRI Shapefile).
#' @export
scrape_high_plains_aquifer_boundary <- function(base_url="https://water.usgs.gov/GIS/metadata/usgswrd/XML/ds543.xml"){
  if(!dir.exists("boundaries")){
    dir.create("boundaries")
  }
  hrefs <- xml2::read_html(base_url)
  hrefs <- rvest::xml_nodes(hrefs,"networkr")
  hrefs <- grep_by(hrefs,pattern="ds543")
  hrefs <- parse_url(hrefs,pattern="zip$")

  zip_name <-  unlist(lapply(strsplit(hrefs,split="/"), FUN=function(x) x[length(x)]))
    zip_name <- file.path(paste("boundaries/",zip_name,sep=""))
  utils::download.file(hrefs[1],destfile=zip_name,quiet=T);
  return(zip_name)
}
#' scrape well-point water data from the USGS portal
#' @export
scrape_well_point_data <- function( base_url="https://ne.water.usgs.gov/projects/HPA/", years=1995:(as.numeric(format(Sys.time(), "%Y"))), quiet=T){
  hrefs <- Ogallala:::parse_hrefs(paste(base_url,"data.html",sep=""))
  hrefs <- Ogallala:::grep_by(hrefs, pattern="WL_ALL_")
  hrefs <- Ogallala:::grep_by(hrefs, pattern=paste(years, collapse="|"))
  hrefs <- Ogallala:::parse_url(hrefs,pattern="zip$")
  # set up our directory structure
  if(!dir.exists("well_point_data")){
    dir.create("well_point_data")
  }
  # define the zips we will fetch and the zips we already have
  zip_names <-  unlist(lapply(strsplit(hrefs,split="/"), FUN=function(x) x[length(x)]))
  to_get <- paste("https://ne.water.usgs.gov/projects/HPA/",hrefs,sep="")
  existing_zips <- list.files("well_point_data",pattern="^WL_ALL_.*.zip$")
    existing_zips <- existing_zips[grepl(existing_zips,pattern=paste(years,collapse="|"))]
  # fetch any well point zips we don't already have
  if(length(existing_zips) < length(to_get)){
    if(length(existing_zips)>0){
      for(i in 1:length(existing_zips)){
        to_get <- to_get[which(!grepl(to_get,pattern=existing_zips[i]))]
        zip_names <- zip_names[which(!grepl(zip_names,pattern=existing_zips[i]))]
      }
    }
    for(i in 1:length(to_get)){
      utils::download.file(to_get[i],destfile=paste("well_point_data",
                                                   zip_names[i],sep="/"),
                                                   quiet=quiet);
    }
  }
  ret <- list.files("well_point_data",pattern="^WL_ALL_.*.zip$",full.names=T)
    ret <- ret[grepl(ret,pattern=paste(years,collapse="|"))]
  cat("\n");
  return(ret)
}
#' scrape aquifer base elevation data
#  see: https://water.usgs.gov/GIS/metadata/usgswrd/XML/ofr98-393_aqbase.xml
#  note: [ELEV] field : base of aquifer elevation is in feet, not meters
scrap_base_elevation <- function(base_url="https://water.usgs.gov/GIS/metadata/usgswrd/XML/ofr98-393_aqbase.xml"){
  hrefs <- xml2::read_html(base_url)
  hrefs <- rvest::xml_nodes(hrefs,"networkr")
  hrefs <- hrefs[grepl(hrefs,pattern="e00")]
  hrefs <- unlist(lapply(strsplit(as.character(hrefs),split=">|<"),function(x) x[3]))
  download.file(hrefs,destfile="ofr98-393.e00.gz")
}
#' scrape polygon features for areas reported to contain little-or-no saturated
#' thickness that lack well data and are thus not captured in the HP Water
#' Monitoring study.
scrape_unsampled_zero_values <- function(base_url="https://water.usgs.gov/GIS/metadata/usgswrd/XML/ofr99-266.xml"){
  hrefs <- xml2::read_html(base_url)
  hrefs <- rvest::xml_nodes(hrefs,"networkr")
  hrefs <- hrefs[grepl(hrefs,pattern="e00")]
  hrefs <- unlist(lapply(strsplit(as.character(hrefs),split=">|<"),function(x) x[3]))
  download.file(hrefs,destfile="ofr99-266.e00.gz")
}
#' unpack a ofr99-266 vector dataset 
unpack_unsampled_zero_values <- function(x="ofr99-266.e00"){
  x = list.files(".",pattern=x)[1]
  if(!file.exists(x)) stop("couldn't find aquifer base elevation contour data in cwd. use a better x= argument")
  if(grepl(x,pattern="gz")) R.utils::gunzip(x,overwrite=T)
  x <- rgdal::readOGR("ofr99-266.e00",verbose=F)
    return(sp::spTransform(x,sp::CRS(raster::projection("+init=epsg:2163"))))
}
#' hidden function that unpacks and processes well point data, returning to
#' user as CSV
unpack_well_point_data <- function(x=NULL){
  default_projection <- "+proj=longlat +datum=NAD83 +no_defs" # strange projection (proj will figure it out)
  unpack_file <- function(x){
    f <- utils::unzip(x,list=T)[,1]; # get a file listing
         utils::unzip(x)             # actually decompress the file
    f <-read.csv(f,sep="\t",comment.char="#",stringsAsFactors=FALSE)
      f[f<=-999] <- NA # looming NA values in the source CSV have inconsistently large values. Treat as NA's
      f[f>=9999] <- NA
        f <- f[!(is.na(f$lat_dd_NAD83) | is.na(f$lat_dd_NAD83)),]
    f <- sp::SpatialPointsDataFrame(coords=data.frame(x=f$long_dd_NAD83,y=f$lat_dd_NAD83),data=f,proj4string=sp::CRS(default_projection))
    return(sp::spTransform(f,sp::CRS(raster::projection("+init=epsg:2163"))))
  }
  if(length(x)>1){
    return(lapply(x,unpack_file))
  } else {
    return(unpack_file(x))
  }
}
#' unpack base elevation data
#' @export
unpack_base_elevation <- function(x="ofr98-393.e00"){
  x = list.files(".",pattern=x)[1]
  if(!file.exists(x)) stop("couldn't find aquifer base elevation contour data in cwd. use a better x= argument")
  if(grepl(x,pattern="gz")) R.utils::gunzip(x,overwrite=T)
  x <- rgdal::readOGR("ofr98-393.e00",verbose=F)
    return(sp::spTransform(x,sp::CRS(raster::projection("+init=epsg:2163"))))
}
#' unpack aquifer boundary data from a zipped ESRI shapefile, as returned by
#' scrapeHighPlainsAquiferBoundary()
#' @export
unpack_high_plains_aquifer_boundary <- function(x="ds543.zip"){
  x <- file.path(list.files(".",pattern="ds543.zip",recursive=T))
  if(!file.exists(x)) stop("couldn't find high plains boundary contour data in cwd. use a better x= argument")
  f <- utils::unzip(x,list=T,)[1,1];        # get a file listing
       utils::unzip(x,exdir="boundaries")             # actually decompress the file

  f <- gsub(f,pattern="[.]...", replacement="") # get layer name
  return(rgdal::readOGR("boundaries",f,verbose=F))
}
