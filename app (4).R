# Oʻahu Fire Station Accessibility – Shiny app (v3)
#
# Two tools on one map:
#  A. Station service areas: pick a station from the dropdown (or click its
#     marker on the map) to see its own 1–10 minute drive range. "Show all"
#     shows the island-wide "minutes to nearest station" shading.
#  B. Address search: type an address, date, and time to find the nearest
#     station by drive time and draw the route.
#
# Mapbox token must already be set, e.g. once in the console:
#   mapboxapi::mb_access_token("pk.xxxx", install = TRUE)

library(shiny)
library(raster)      # load before dplyr so dplyr::select isn't masked
library(fasterize)
library(sf)
library(dplyr)
library(leaflet)
library(mapboxapi)

`%||%` <- function(a, b) if (is.null(a)) b else a
token <- get_mb_access_token()

# ---- Data -------------------------------------------------------------------

fire_oahu <- st_read("data/Statewide_Fire_Stations.geojson", quiet = TRUE) %>%
  filter(island == "Oahu") %>%
  st_transform(4326)

# Isochrones for one departure time (one set of 1–10 min polygons per
# station, labelled by station name in the `id` column). Cached to disk.
build_isos <- function(depart) {
  f <- file.path("data", paste0("fire_isos_", gsub("[:]", "", depart), ".rds"))
  if (!file.exists(f)) {
    isos <- mb_isochrone(fire_oahu, profile = "driving", time = 1:10,
                         depart_at = depart, id_column = "name")
    saveRDS(isos, f)
  }
  st_transform(readRDS(f), 4326)
}

# "Minutes to nearest station" surface built from those isochrones. Cached.
build_surface <- function(depart, isos) {
  f <- file.path("data", paste0("fire_surface_", gsub("[:]", "", depart), ".tif"))
  if (!file.exists(f)) {
    isos_proj <- st_transform(isos, 32604)          # UTM zone 4N
    template  <- raster(isos_proj, resolution = 100)
    surf      <- fasterize(isos_proj, template, field = "time", fun = "min")
    writeRaster(surf, f, overwrite = TRUE)
  }
  raster(f)
}

default_depart <- "2026-10-01T16:00"
default_isos   <- build_isos(default_depart)
default_surf   <- build_surface(default_depart, default_isos)

surface_pal <- colorNumeric("plasma", 1:10, na.color = "transparent")
station_pal <- colorFactor(hcl.colors(nrow(fire_oahu), "Dark 3"),
                           domain = fire_oahu$name)

oahu_bbox <- c(-158.30, 21.25, -157.64, 21.72)
time_choices <- format(seq(as.POSIXct("2000-01-01 00:00"),
                           by = "15 min", length.out = 96), "%H:%M")
station_choices <- c("Show all (nearest station)" = "all",
                     "Map only (no shading)"      = "none",
                     sort(unique(fire_oahu$name)))

# ---- Mapbox helpers (direct API calls, so errors are visible) --------------

mapbox_get <- function(url, query) {
  res  <- httr::GET(url, query = c(query, access_token = token))
  body <- jsonlite::fromJSON(httr::content(res, "text", encoding = "UTF-8"),
                             simplifyVector = FALSE)
  if (httr::status_code(res) != 200) {
    stop(body$message %||% paste("HTTP", httr::status_code(res)), call. = FALSE)
  }
  body
}

# Mapbox's Geocoding. This function turns an address we type into a point on the map. 
# It sentds text like'3140 Waialae Ave' and it replies with the locataion cordinates official address. 
geocode_oahu <- function(address) {
  url  <- paste0("https://api.mapbox.com/geocoding/v5/mapbox.places/", # Geocoding API code 
                 URLencode(address, reserved = TRUE), ".json")
  body <- mapbox_get(url, list(bbox = paste(oahu_bbox, collapse = ","),
                               limit = 1, country = "us"))
  if (length(body$features) == 0) return(NULL)
  ft <- body$features[[1]] # handle null
  st_sf(place_name = ft$place_name,
        geometry = st_sfc(st_point(unlist(ft$center)), crs = 4326))
}

# Station -> address drive at a given departure time
drive_route <- function(from, to, depart) {
  url <- sprintf(
    "https://api.mapbox.com/directions/v5/mapbox/driving-traffic/%.6f,%.6f;%.6f,%.6f",
    from[1], from[2], to[1], to[2])
  body <- mapbox_get(url, list(depart_at = depart, geometries = "geojson",
                               overview = "full"))
  if (body$code != "Ok") stop(body$message %||% body$code, call. = FALSE)
  r <- body$routes[[1]]
  coords <- do.call(rbind, lapply(r$geometry$coordinates, unlist))
  list(minutes  = r$duration / 60,
       typical  = (r$duration_typical %||% NA) / 60,
       km       = r$distance / 1000,
       geometry = st_linestring(coords))
}

# ---- UI ---------------------------------------------------------------------

ui <- fluidPage(
  titlePanel("Oʻahu Fire Station Drive Times"),
  sidebarLayout(
    sidebarPanel(
      width = 3,

      h4("Station service areas"),
      selectInput("selected_station", "Select fire station:",
                  choices = station_choices, selected = "all"),
      helpText("Or click any station marker on the map."),
      checkboxInput("show_shading", "Show shading zone", value = TRUE),
      hr(),

      h4("Find nearest station"),
      textInput("address", "Address",
                placeholder = "e.g. 3140 Waialae Ave, Honolulu"),
      dateInput("date", "Date", value = Sys.Date()),
      selectInput("time", "Time", choices = time_choices, selected = "16:00"),
      actionButton("go", "Find nearest station", class = "btn-primary"),
      br(), br(),
      actionButton("redo_surface", "Update map shading for this date/time",
                   class = "btn-sm"),
      helpText("Optional. Rebuilds the shading for the chosen date/time.",
               "Slow the first time for each date/time, then cached."),
      hr(),
      uiOutput("summary"),
      tableOutput("top_stations")
    ),
    mainPanel(
      width = 9,
      textOutput("surface_label"),
      leafletOutput("map", height = "85vh")
    )
  )
)

# ---- Server -----------------------------------------------------------------

server <- function(input, output, session) {

  depart_str   <- reactive(paste0(format(input$date, "%Y-%m-%d"), "T", input$time))
  surface_time <- reactiveVal(default_depart)
  current_isos <- reactiveVal(default_isos)
  current_surf <- reactiveVal(default_surf)

  # Text above the map describing what the shading shows
  shading_label <- reactiveVal(
    paste("Shading: minutes to the nearest station, departing",
          sub("T", " at ", default_depart)))
  output$surface_label <- renderText(shading_label())

  # Set to TRUE when a search changes the dropdown, so the dropdown
  # observer doesn't redraw over the search's own shading
  skip_redraw <- FALSE

  # Draw one station's 1–10 minute range (polygons stacked, big first)
  draw_station_iso <- function(polys, fly = TRUE) {
    polys <- arrange(polys, desc(time))
    proxy <- leafletProxy("map") %>%
      clearGroup("surface") %>%
      clearGroup("station_iso") %>%
      addPolygons(data = polys, group = "station_iso",
                  fillColor = ~surface_pal(time), fillOpacity = 0.15,
                  stroke = FALSE, label = ~paste(time, "min"))
    if (fly) {
      bb <- st_bbox(polys)
      proxy %>% flyToBounds(bb[["xmin"]], bb[["ymin"]],
                            bb[["xmax"]], bb[["ymax"]])
    }
  }

  # Base map (starts in "Show all" mode)
  output$map <- renderLeaflet({
    leaflet() %>%
      addMapboxTiles(style_id = "light-v9", username = "mapbox",
                     scaling_factor = "0.5x") %>%
      addRasterImage(default_surf, colors = surface_pal, opacity = 0.45,
                     method = "ngb", group = "surface") %>%
      addCircleMarkers(data = fire_oahu, radius = 5, stroke = TRUE,
                       color = "white", weight = 1,
                       fillColor = ~station_pal(name), fillOpacity = 0.95,
                       label = ~name, layerId = ~name) %>%
      addLegend(values = 1:10, pal = surface_pal,
                title = "Drive time<br>(minutes)", group = "legend")
  })

  # Show or hide every shading layer (and its legend) to match the checkbox.
  # Called after each redraw so new shading respects an unchecked box.
  shading_groups <- c("surface", "station_iso", "legend")
  sync_shading_visibility <- function() {
    proxy <- leafletProxy("map")
    if (isTRUE(input$show_shading)) {
      showGroup(proxy, shading_groups)
    } else {
      hideGroup(proxy, shading_groups)
    }
  }

  observeEvent(input$show_shading, sync_shading_visibility(), ignoreInit = TRUE)

  # Clicking a station marker selects it in the dropdown
  observeEvent(input$map_marker_click, {
    id <- input$map_marker_click$id
    if (!is.null(id) && id %in% fire_oahu$name) {
      updateSelectInput(session, "selected_station", selected = id)
    }
  })

  # Redraw shading when the selection or the date/time data changes
  observeEvent(list(input$selected_station, current_isos(), current_surf()), {
    if (skip_redraw) {            # change came from a search; already drawn
      skip_redraw <<- FALSE
      return()
    }
    sel  <- input$selected_station
    when <- sub("T", " at ", surface_time())

    if (sel == "all") {
      leafletProxy("map") %>%
        clearGroup("surface") %>%
        clearGroup("station_iso") %>%
        addRasterImage(current_surf(), colors = surface_pal, opacity = 0.45,
                       method = "ngb", group = "surface")
      shading_label(paste("Shading: minutes to the nearest station, departing", when))
    } else if (sel == "none") {
      leafletProxy("map") %>%
        clearGroup("surface") %>%
        clearGroup("station_iso")
      shading_label("Shading hidden")
    } else {
      polys <- filter(current_isos(), id == sel)
      req(nrow(polys) > 0)
      draw_station_iso(polys)
      shading_label(paste0("Shading: 1–10 minute drive range of ", sel,
                           " station, departing ", when))
    }
    sync_shading_visibility()
  }, ignoreInit = TRUE)

  # Rebuild isochrones + surface for the chosen date/time
  observeEvent(input$redo_surface, {
    depart <- depart_str()
    ok <- withProgress(message = "Building drive-time areas…", value = 0.3, {
      tryCatch({
        isos <- build_isos(depart)
        incProgress(0.4)
        surf <- build_surface(depart, isos)
        current_isos(isos)
        current_surf(surf)
        surface_time(depart)
        TRUE
      }, error = function(e) {
        showNotification(paste("Shading failed:", conditionMessage(e)),
                         type = "error", duration = 10)
        FALSE
      })
    })
  })

  # ---- Address search ----------------------------------------------------

  result <- eventReactive(input$go, {
    req(nzchar(trimws(input$address)))
    depart <- depart_str()

    withProgress(message = "Finding nearest station…", value = 0.1, {

      # 1. Geocode
      addr <- tryCatch(geocode_oahu(input$address), error = function(e) {
        shiny::validate(paste("Geocoding error:", conditionMessage(e)))
      })
      shiny::validate(need(!is.null(addr),
                    "Couldn't find that address on Oʻahu. Try adding 'Honolulu, HI'."))
      to <- as.numeric(st_coordinates(addr))

      # 2. 9 closest stations by straight-line distance
      dist <- st_distance(st_transform(fire_oahu, 32604),
                          st_transform(addr, 32604))
      cand <- fire_oahu[order(as.numeric(dist))[1:min(9, nrow(fire_oahu))], ]

      # 3. Time-dependent drive for each candidate (station -> address)
      errors <- character(0)
      routes <- lapply(seq_len(nrow(cand)), function(i) {
        incProgress(0.09)
        from <- as.numeric(st_coordinates(cand[i, ]))
        tryCatch(drive_route(from, to, depart), error = function(e) {
          errors <<- c(errors, conditionMessage(e))
          NULL
        })
      })
      ok <- !vapply(routes, is.null, logical(1))
      shiny::validate(need(any(ok), paste("Mapbox Directions error:",
                                   paste(unique(errors), collapse = "; "))))

      cand    <- cand[ok, ]
      routes  <- routes[ok]
      cand$minutes <- round(vapply(routes, `[[`, numeric(1), "minutes"), 1)
      cand$typical <- round(vapply(routes, `[[`, numeric(1), "typical"), 1)
      cand$km      <- round(vapply(routes, `[[`, numeric(1), "km"), 1)

      best  <- which.min(cand$minutes)
      route <- st_sf(geometry = st_sfc(routes[[best]]$geometry, crs = 4326))

      # 4. Drive range of the nearest station at the searched date/time
      #    (only one station, so this is quick)
      iso <- tryCatch(
        mb_isochrone(cand[best, ], profile = "driving", time = 1:10,
                     depart_at = depart, id_column = "name") %>%
          st_transform(4326),
        error = function(e) NULL)

      list(addr = addr, cand = arrange(cand, minutes),
           nearest = cand[best, ], route = route, depart = depart, iso = iso)
    })
  })

  observeEvent(result(), {
    r    <- result()
    name <- r$nearest$name

    # Automatically shade the nearest station's drive range.
    # Use the range for the searched time; if that failed, fall back to
    # the cached one for the shading's date/time.
    polys <- r$iso
    when  <- r$depart
    if (is.null(polys) || nrow(polys) == 0) {
      polys <- filter(current_isos(), id == name)
      when  <- surface_time()
    }
    if (nrow(polys) > 0) {
      draw_station_iso(polys, fly = FALSE)   # keep the view on the route
      shading_label(paste0("Shading: 1–10 minute drive range of ", name,
                           " station (nearest), departing ",
                           sub("T", " at ", when)))
      sync_shading_visibility()
    }

    # Sync the dropdown without triggering a second redraw
    if (!identical(input$selected_station, name)) {
      skip_redraw <<- TRUE
      updateSelectInput(session, "selected_station", selected = name)
    }

    bb <- st_bbox(rbind(st_sf(geometry = st_geometry(r$route)),
                        st_sf(geometry = st_geometry(r$addr))))
    leafletProxy("map") %>%
      clearGroup("result") %>%
      addPolylines(data = r$route, group = "result",
                   color = station_pal(r$nearest$name),
                   weight = 5, opacity = 0.9) %>%
      addCircleMarkers(data = r$nearest, group = "result", radius = 10,
                       color = "black", weight = 2,
                       fillColor = station_pal(r$nearest$name),
                       fillOpacity = 1, label = ~name) %>%
      addMarkers(data = r$addr, group = "result", label = r$addr$place_name) %>%
      flyToBounds(bb[["xmin"]], bb[["ymin"]], bb[["xmax"]], bb[["ymax"]])
  })

  output$summary <- renderUI({
    r <- result()
    tagList(
      h4(r$nearest$name),
      p(strong(paste0(r$nearest$minutes, " min")), " drive to the address",
        paste0("(", r$nearest$km, " km)")),
      if (!is.na(r$nearest$typical))
        p(paste0("Typical for this route: ", r$nearest$typical, " min")),
      p(em(paste("Matched address:", r$addr$place_name))),
      p(em(paste("Departing", sub("T", " at ", r$depart))))
    )
  })

  output$top_stations <- renderTable({
    r <- result()
    r$cand %>%
      st_drop_geometry() %>%
      transmute(Station = name, `Drive (min)` = minutes) %>%
      head(5)
  })
}

shinyApp(ui, server)
