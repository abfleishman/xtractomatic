#' Extract environmental data along a trajectory using ERDDAP.
#'
#' \code{xtracto} uses the ERD ERDDAP data web service to extact environmental
#' data along a longitude, latitude and time trajectory
#' @export
#' @param xpos - a real array with the longitudes of the trajectory (in decimal
#'   degrees East, either 0-360 or -180 to 180)
#' @param ypos -  a real array with the latitudes of the trajectory (in decimal
#'   degrees N; -90 to 90)
#' @param tpos - a character array with the times of the trajectory in
#'   "YYYY-MM-DD"
#' @param dtype - number or string identfying the ERDDAP parameter to extract
#' @param xlen - real array defining the longitude box around the given point (xlen/2 around the point)
#' @param ylen - real array defining the latitude box around the given point (tlen/2 around the point)
#' @param verbose - logical for verbose download out, default FALSE
#' @return A dataframe containing:
#' \itemize{
#'  \item column 1 = mean of data within search radius
#'  \item column 2 = standard deviation of data within search radius
#'  \item column 3 = number of points found within search radius
#'  \item column 4 = time of returned value
#'  \item column 5 = min longitude of call (decimal degrees)
#'  \item column 6 = max longitude of call (decimal degrees)
#'  \item column 7 = min latitude of call (decimal degrees)
#'  \item column 8 = max latitude of call (decimal degrees)
#'  \item column 9 = requested time in tag
#'  \item column 10 = median of data within search radius
#'  \item column 11 = median absolute deviation of data within search radius
#'  }
#' @examples
#' xpos <- c(230, 235)
#' ypos <- c(40, 45)
#' tpos <- c('2006-01-15', '2006-01-20')
#' xlen <- 0.05
#' ylen <- 0.05
#' extract <- xtracto(xpos, ypos, tpos, 150, xlen, ylen)
#' \donttest{
#' extract <- xtracto(xpos, ypos,tpos, 150, xlen, ylen, verbose = TRUE)
#' extract <- xtracto(xpos, ypos, tpos, 'erdMBsstd8day', xlen, ylen)
#' }
#'




xtracto <- function(xpos, ypos, tpos, dtype, xlen, ylen, verbose = FALSE){
  # default URL for NMFS/SWFSC/ERD  ERDDAP server
  urlbase <- 'https://coastwatch.pfeg.noaa.gov/erddap/griddap/'
  urlbase1 <- 'https://coastwatch.pfeg.noaa.gov/erddap/tabledap/allDatasets.csv?'
  structLength <- nrow(erddapStruct)
  lengthXpos <- length(xpos)
  lengthYpos <- length(ypos)
  lengthTpos <- length(tpos)
  lengthtest <- identical(lengthXpos, lengthYpos) & identical(lengthXpos, lengthTpos)
  if (!lengthtest) {
    print('input vectors are not of the same length')
    print(paste0('length of xpos: ', lengthXpos))
    print(paste0('length of ypos: ', lengthYpos))
    print(paste0('length of tpos: ', lengthTpos))
    return()
  }
  if (is.character(dtype)) {
    dtypePresent <- dtype %in% erddapStruct$dtypename
    if (!dtypePresent) {
      print(paste0('dataset name: ', dtype))
      stop('no matching dataset found')
    }
    dataStruct <- subset(erddapStruct, erddapStruct$dtypename == dtype)
  } else {
    if ((dtype < 1) | (dtype > structLength)) {
      print(paste0('dataset number out of range - must be between 1 and', structLength, dtype))
      stop('no matching dataset found')
    }
    dataStruct <- erddapStruct[dtype, 1:19]
  }

  #reconcile longitude grids
  xpos1 <- xpos
  #grid is not 360, xpos is
  if (dataStruct$lon360) {
    xpos1 <- make360(xpos1)
  } else {
    xpos1 <- make180(xpos1)
  }
  # deal with xlen = constant v. vector
  if (length(xlen) == 1) {
    xrad <- c(rep(xlen, length(xpos)))
    yrad <- c(rep(ylen, length(ypos)))
  } else {
    xrad <- xlen
    yrad <- ylen
  }

  # Bathymetry is a special case lets get it out of the way
  if (dataStruct$datasetname == "etopo360" || dataStruct$datasetname == "etopo180") {
    result <- getETOPOtrack(dataStruct, xpos1, ypos, xrad, yrad, verbose)
    if (result$returnCode == -1) {
      stop('error in getting ETOPO data - see error messages')
    } else {
      return(result$out.dataframe)
    }
  }
dataStruct <- getMaxTime(dataStruct)

udtpos <- as.Date(tpos, origin = '1970-01-01', tz = "GMT")
xposLim <- c(min(xpos1 - (xrad/2)), max(xpos1 + (xrad/2)))
yposLim <- c(min(ypos - (yrad/2)), max(ypos + (yrad/2)))
tposLim <- c(min(udtpos), max(udtpos))

#check that coordinate bounds are contained in the dataset

result <- checkBounds(dataStruct, xposLim, yposLim, tposLim)
if (result != 0) {
  stop("Coordinates out of dataset bounds - see messages above")
}


#get dimension info
dataCoordList <- getfileCoords(dataStruct)
if (!is.list(dataCoordList)) {
  stop("Error retrieving coordinate variable")
}
isotime <- dataCoordList[[1]]
udtime <- dataCoordList[[2]]
latitude <- dataCoordList[[3]]
longitude <- dataCoordList[[4]]
if (dataStruct$hasAlt) {
  altitude <- dataCoordList[[5]]
}

#create structures to store last request in case it is the same
out.dataframe <- as.data.frame(matrix(ncol = 11, nrow = length(xpos)))
dimnames(out.dataframe)[[2]] <- c('mean', 'stdev', 'n', 'satellite date', 'requested lon min', 'requested lon max', 'requested lat min', 'requested lat max', 'requested date', 'median', 'mad')
oldLonIndex <-  rep(NA_integer_, 2)
oldLatIndex <-  rep(NA_integer_, 2)
oldTimeIndex <-  rep(NA_integer_, 2)
newLonIndex <-  rep(NA_integer_, 2)
newLatIndex <-  rep(NA_integer_, 2)
newTimeIndex <-  rep(NA_integer_, 2)
oldDataFrame <- as.data.frame(matrix(ncol = 11,nrow = 1))


for (i in 1:length(xpos1)) {

# define bounding box
  xmax <- xpos1[i] + (xrad[i]/2)
  xmin <- xpos1[i] - (xrad[i]/2)
  if (dataStruct$latSouth) {
     ymax <- ypos[i] + (yrad[i]/2)
     ymin <- ypos[i] - (yrad[i]/2)
  } else {
     ymin <- ypos[i] + (yrad[i]/2)
     ymax <- ypos[i] - (yrad[i]/2)
  }


# find closest time of available data
#map request limits to nearest ERDDAP coordinates
   newLatIndex[1] <- which.min(abs(latitude - ymin))
   newLatIndex[2] <- which.min(abs(latitude - ymax))
   newLonIndex[1] <- which.min(abs(longitude - xmin))
   newLonIndex[2] <- which.min(abs(longitude - xmax))
   newTimeIndex[1] <- which.min(abs(udtime - udtpos[i]))

   if (identical(newLatIndex, oldLatIndex) && identical(newLonIndex, oldLonIndex) && identical(newTimeIndex[1], oldTimeIndex[1])) {
     # the call will be the same as last time, so no need to repeat
     out.dataframe[i,] <- oldDataFrame
   } else {
     erddapLats <- rep(NA_real_, 2)
     erddapLons <- rep(NA_real_, 2)
     erddapTimes <- rep(NA_real_, 2)
     erddapLats[1] <- latitude[newLatIndex[1]]
     erddapLats[2] <- latitude[newLatIndex[2]]
     erddapLons[1] <- longitude[newLonIndex[1]]
     erddapLons[2] <- longitude[newLonIndex[2]]
     requesttime <- isotime[newTimeIndex[1]]
     erddapTimes[1] <- requesttime
     erddapTimes[2] <- requesttime

     myURL <- buildURL(dataStruct, erddapLons, erddapLats, erddapTimes)
     #Download the data from the website to the current R directory
     fileout <- "tempExtract.nc"
     downloadReturn <- getErddapURL(myURL, fileout, verbose)
     if (downloadReturn != 0) {
       print(myURL)
       stop("There was an error in the url call.  See message on screen and URL called")
     }


     datafileID <- ncdf4::nc_open(fileout)

     # Store in a dataframe
     paramdata <- as.vector(ncdf4::ncvar_get(datafileID))

     # close netcdf file
     ncdf4::nc_close(datafileID)

    #  put xmin, xmax on requesting scale
     if (max(xpos) > 180.) {
      xmin <- make360(xmin)
      xmax <- make360(xmax)
     }
    #request is on (-180,180)
    if (min(xpos) < 0.) {
      xmin <- make180(xmin)
      xmax <- make180(xmax)
    }

     out.dataframe[i, 1] <- mean(paramdata, na.rm = T)
     out.dataframe[i, 2] <- stats::sd(paramdata, na.rm = T)
     out.dataframe[i, 3] <- length(stats::na.omit(paramdata))
     out.dataframe[i, 4] <- requesttime
     out.dataframe[i, 5] <- xmin
     out.dataframe[i, 6] <- xmax
     out.dataframe[i, 7] <- ymin
     out.dataframe[i, 8] <- ymax
     out.dataframe[i, 9] <- tpos[i]
     out.dataframe[i, 10] <- stats::median(paramdata, na.rm = T)
     out.dataframe[i, 11] <- stats::mad(paramdata, na.rm = T)

     # clean thing up
     # remove temporary file
     if (file.exists(fileout)) {
       file.remove(fileout)
     }
     # remove variable from workspace
     remove('paramdata')
   }
   oldLatIndex <- newLatIndex
   oldLonIndex <- newLonIndex
   oldTimeIndex <- newTimeIndex
   oldDataFrame <- out.dataframe[i,]

}
return(out.dataframe)
}

