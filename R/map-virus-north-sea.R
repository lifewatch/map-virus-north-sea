library(EMODnetWFS)
library(EMODnetWCS)
library(ows4R)
library(sf)
library(magrittr)
library(terra)
library(tidyterra)
library(ggplot2)
library(raster)
library(ggspatial)
library(rerddap)
library(RNetCDF)

# Set stations
stations <- read.csv("./data/raw/PE477_PE486_cruise_coordinates.csv", sep = ";") %>% sf::st_as_sf(
  coords = c("longitude", "latitude"),
  remove = FALSE,
  crs = 4326
)

# Extract station number
stations$Station <- strsplit(stations$name, split = "-", fixed = TRUE) %>%
  lapply(`[[`, index = 2) %>%
  unlist()

# Split cause two stations are too close to each other and it is not readable
station_PE486_7 <- subset(stations, stations$name == "PE486-7")
stations <- subset(stations, stations$name != "PE486-7")

# # Use these lines to select a region interactively. Copy paste the WKT polygon
# x <- mapedit::editMap(mapview::mapview(stations))
# st_as_text(st_multipolygon(st_geometry(x$drawn)))

# Define area bounding box
frame <- st_as_sfc("MULTIPOLYGON (((-0.391711 53.22202, -0.391711 55.71748, 4.617073 55.71748, 4.617073 53.22202, -0.391711 53.22202)))", crs = 4326)
bbox <- st_bbox(frame)
bbox_url <- paste0(bbox, collapse = ",")

# Get Currents by editing the netcdf file
# Previously downloaded from Copernicus - need to automatize
cur <- open.nc("./data/raw/cmems_mod_glo_phy-cur_anfc_0.083deg_P1M-m_1702481350907.nc", write = TRUE)
print.nc(cur)

# Calculate current direction in degrees
calc_dir <-function(vo, uo) (atan2(vo, uo) * (180 / pi)) + 180
current_direction <- calc_dir(
  var.get.nc(cur, "vo"),
  var.get.nc(cur, "uo")
)

# Add missing dimensions
dim(current_direction) <- c(dim(current_direction), 1, 1)

# Create variable and put data
var.def.nc(cur, varname = "dir", vartype = "NC_DOUBLE",
           dimensions = c("longitude", "latitude", "depth", "time"))
att.put.nc(cur, "dir", name = "standard_name", type = "NC_CHAR", value = "sea_water_velocity_to_direction")
att.put.nc(cur, "dir", name = "long_name", type = "NC_CHAR", value = "Direction of Sea Water")
att.put.nc(cur, "dir", name = "units", type = "NC_CHAR", value = "degree")
var.put.nc(cur, "dir", data = current_direction)

# Inspect and close
print.nc(cur)
sync.nc(cur)
close.nc(cur)

# Open as raster
cur <- rast("./data/raw/cmems_mod_glo_phy-cur_anfc_0.083deg_P1M-m_1702481350907.nc")
cur <- cur$`dir_depth=0.49402499`

# Get coastline
wfs <- WFSClient$new("https://geo.vliz.be/geoserver/MarineRegions/wfs", "1.0.0")
countries <- wfs$getFeatures("MarineRegions:worldcountries_esri_2014", BBOX = bbox_url, outputFormat="application/json", srsName="EPSG:4326")

# Crop countries to bounding box
countries <- countries %>% st_intersection(frame)
# mapview::mapview(countries)

# Get EEZ
eez <- wfs$getFeatures("MarineRegions:eez_boundaries",
                       outputFormat="application/json",
                       srsName="EPSG:4326",
                       cql_filter = "line_name IN ('Netherlands - United Kingdom', 'Netherlands - Germany', 'Germany - Denmark')")

# Crop EEZ to bounding box
eez <- eez %>% st_intersection(frame)

# Write labels of country EEZs
eez_label <- data.frame(
  eez = c("GBR", "NLD", "DEU"),
  latitude = c(53.8, 53.33, 55.53),
  longitude = c(-0.2, 4.3, 4.3)
) %>% st_as_sf(
  coords = c("longitude", "latitude"),
  crs = 4326
)

# Download bathymetry
res <- griddap(
  datasetx = "bathymetry_2022",
  url = "https://erddap.emodnet.eu/erddap/",
  fields = "elevation",
  latitude = c(bbox$ymin, bbox$ymax),
  longitude = c(bbox$xmin, bbox$xmax),
  store = disk("./data/raw/")
)

# Read as SpatRaster
bathymetry <- rast(res$summary$filename)

# Mask bathymetry
bathymetry <- mask(bathymetry, countries, inverse = TRUE)

# Remove bathymetry values above 0
bathymetry[bathymetry > 0] <- NA

# Define bathymetry scale
breaks_bath <- seq(from = 0, to = -115, by = -20)
labels_bath <- as.character(bath_scale_n * -1)

# Plot
map <- ggplot() +
  theme(
    axis.title.x = element_blank(),
    axis.title.y = element_blank()) +

  # Add Bathymetry
  geom_spatraster(data = bathymetry) +
  scale_fill_hypso_c(
    "wiki-2.0_bathy",
    name = "Depth (m)",
    breaks = breaks_bath,
    labels = labels_bath
  ) +

  # Add countries and boundaries background
  geom_sf(mapping = aes(), data = countries) +
  geom_sf(mapping = aes(), data = eez, linetype = "dashed", alpha = 0.9) +
  geom_sf_text(mapping = aes(label = eez_label$eez, geometry = eez_label$geometry), size = 3) +

  # Add stations with shading
  geom_sf(mapping = aes(color = cruise), data = stations, size = 4) +
  geom_sf(mapping = aes(color = cruise), data = station_PE486_7, size = 4) +
  scale_color_manual(values = alpha(c("PE477" = "#af8dc3", "PE486" = "#7fbf7b"), .7)) +

  # Add station labels
  geom_sf_text(aes(label = stations$Station, geometry = stations$geometry),
               nudge_x = 0.10, nudge_y = 0.05
  ) +
  geom_sf_text(aes(label = station_PE486_7$Station, geometry = station_PE486_7$geometry),
               nudge_x = -0.10, nudge_y = -0.05
  ) +

  # Add north arrow and scalebar
  annotation_north_arrow(
    pad_x = unit(1.3, "cm"),
    pad_y = unit(0.8, "cm"),
    location = "bl", style = north_arrow_orienteering(
      text_size = 8,
      fill = c("grey95", "grey5")
    )) +
  annotation_scale(
    location = "bl",
    bar_cols = c("grey95", "grey5"),
    pad_x = unit(3.4, "cm"),
    pad_y = unit(1.2, "cm")
  )

map

# Save using Rstudio export tool

