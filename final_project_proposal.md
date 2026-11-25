# DS 422 Geocomputation – Final Project Proposal
 
**Name:**
 Rei Miyashiro
**Date:**
 11/24/2026
---
 
Fill this out before you start on your analysis. Write your answers under each question. A few sentences is fine for most of them. Be specific, though: "I'll look at land use" is too vague, but "I'll compare sugar land change across Maui from 2001 to 2021" is better.
 
Download this file and add it to your DS422 Repository, then edit right in the github browser.
 
---
 
## 1. My research question
 
What do you want to find out? Phrase it as a question. Mention the place and time period if they are relevant.
 
<!-- Write your answer below this line -->
How much has nighttime light in Lahaina, Maui recovered since the August 8, 2023 wildfire, and does the pace of recovery differ across the burn zone? In particular, I will compare the mostly residential neighborhoods with the Front Street commercial district from January 2022 (pre-fire baseline) through the most recent available month in 2026. 
I will also compare the burn zone with nearby unburned areas such as Kāʻanapali, so I can separate the effect of the fire from island-wide changes like the drop in tourism. 


I will answer it through three sub-questions:

1. **How far has it recovered?** Taking the pre-fire brightness as 100%, what percentage of the light has returned to the burn zone so far?
2. **Does recovery differ by place?** Has the mostly residential part of the burn zone recovered faster than the Front Street commercial district? News reports say homes are being rebuilt while the commercial district lags behind, and I will test whether the satellite data shows the same pattern.
3. **Is the change caused by the fire?** By comparing the burn zone with a nearby unburned area (Kāʻanapali), I will separate the effect of the fire from island-wide changes such as the drop in tourism.

**What nighttime light measures here:** Hawaiian Electric had restored power to all West Maui customers who could be reconnected by late August 2023. After that point, changes in brightness reflect buildings being rebuilt, people returning, and businesses reopening, not the state of the power grid. In this project, I use nighttime light as a measure of rebuilding and human activity.
---
 
## 2. The dataset(s) I will use to approach my research question
 
List each dataset and where it comes from (agency, website, link). Note the format (shapefile, raster, CSV with coordinates, etc.) and the spatial and temporal coverage if you know it.
 
<!-- Write your answer below this line -->
 ## 2. The dataset(s) I will use to approach my research question

<!-- Write your answer below this line -->

- **NASA Black Marble VNP46A3 (monthly) and VNP46A2 (daily) nighttime lights** – NASA LAADS DAAC (https://ladsweb.modaps.eosdis.nasa.gov/), downloaded with the `blackmarbler` R package (https://worldbank.github.io/blackmarbler/) using a NASA Earthdata token. Format: HDF5 raster tiles converted to GeoTIFF. Spatial: about 500 m (15 arc-second) resolution, clipped to West Maui. Temporal: January 2022 – most recent available month in 2026. I will mainly use the monthly product for the long-term trend, and the daily product for the weeks right after the fire.

- **Lahaina fire perimeter** – WFIGS Interagency Fire Perimeters, National Interagency Fire Center (https://data-nifc.opendata.arcgis.com/). Format: polygon feature layer, downloaded as GeoJSON. Spatial: the Lahaina Incident burn area (2023-HIMAUX-012492, about 2,124 acres). Temporal: final perimeter of the August 8, 2023 fire. I will use it to define the burned zone and to separate it from unburned areas nearby.

- **U.S. Census TIGER/Line block groups and tracts (2020)** – U.S. Census Bureau, accessed with the `tigris` R package. Format: shapefile. Spatial: Maui County. Temporal: 2020 boundaries. Used to define zones: residential burn area, Front Street commercial area, and an unburned control area (Kāʻanapali).

- **Maui County Recovery Dashboard** – County of Maui (https://www.mauirecovers.org/recoverydashboard). Format: web dashboard (summary figures). Spatial: Lahaina burn zone. Temporal: 2023 – present. Rebuilding progress figures used as ground truth to compare against the nighttime light trends.
 
 
 
 
---
 
## 3. The specific geocomputation techniques I will use to answer my research question
 
What methods will you actually run? For example, image segmentation, spatial statistics, time series analysis etc.
 
<!-- Write your answer below this line -->
 
 ## 3. The specific geocomputation techniques I will use to answer my research question

<!-- Write your answer below this line -->

This project builds on my earlier DS422 assignment, "Detecting a Power Outage from Space" (Oʻahu, Hurricane Lala, August 2026). That assignment used daily Black Marble data over about two weeks. This project uses monthly data over about five years, so some techniques carry over directly, some are adapted, and some are new.

**A. Carried over directly from the Oʻahu outage assignment**

- **Raster retrieval and preprocessing:** Pull Black Marble rasters date by date with `bm_raster()` inside `tryCatch()`, reproject the boundaries from NAD83 to WGS84, mask the rasters to the study area, and remove low-quality pixels with the quality flags.
- **Data completeness check:** Count the valid (non-cloud) pixels for each month, so a month does not look dark just because the observation is missing.
- **Noise-floor masking:** Exclude pixels whose pre-fire brightness is too low to show meaningful change (baseline radiance < 5).
- **Zonal statistics:** Use `exactextractr::exact_extract()` to calculate the mean radiance of each zone for each time step.
- **Raster mapping:** Map the change in radiance with `tidyterra::geom_spatraster()` and interactive `tmap` maps.

**B. Adapted from the Oʻahu outage assignment**

- **Baseline comparison → recovery index:** In the Oʻahu assignment, each storm night was compared with a 7-night baseline mean using percent change and z-scores. Here I will use a multi-year monthly baseline (January 2021 – July 2023) and turn percent change into a monthly **recovery index**: the share of the pre-fire light level that has returned.
- **Zones from fire data instead of counties and places:** In the Oʻahu assignment, I aggregated to counties and Census-designated places. Here I will use the NIFC fire perimeter and Census block groups to build three zones: the residential burn area, the Front Street commercial area, and an unburned control area (Kāʻanapali).
- **Validation against an outside source:** In the Oʻahu assignment, I compared the results with Hawaiian Electric's outage reports. Here I will compare them with the Maui County Recovery Dashboard and news reports on rebuilding.

**C. New techniques for this project**

- **Time series decomposition (STL):** Separate each zone's monthly radiance into seasonal, trend, and remainder components, so seasonal swings (for example, tourist seasons) are not mistaken for recovery.
- **Change point detection:** Use the `changepoint` or `bfast` R package to find when each zone's light dropped and when its recovery sped up or stalled.
- **Control-area comparison (difference-in-differences style):** Compare the burn zones with the unburned control area to separate the effect of the fire from island-wide changes such as the drop in tourism.
- **Pixel-level recovery mapping over time:** Map the recovery index for each pixel at several points in time (for example, 6, 12, 24, and 36 months after the fire) to show where the lights have and have not come back.
 
 
 
---
 
## 4. 3-5 peer-reviewed publications or news articles surrounding my research question
 
Give the link below. Add a sentence or two on why each source is relevant to your project.
 
1. Cao et al. (2025), *Photogrammetric Engineering & Remote Sensing* — https://doi.org/10.14358/PERS.24-00050R2 — The only peer-reviewed study I found that tracks VIIRS night lights after the Lahaina fire, but it looks at a single site. 
My project extends this to the whole burn zone and compares neighborhoods. 

2. Civil Beat (2026), "*Maui wildfires 3 years later"* — https://www.civilbeat.org/2026/08/maui-wildfires-3-years-later-anniversary-lahaina-recovery-continues 
— Ground truth on rebuilding progress (residential vs. the commercial district) to compare against the night-light trends.
 
3. Akter (2023), *Global Environmental Change* — https://doi.org/10.1016/j.gloenvcha.2023.102743 
— Uses monthly nightlights and a difference-in-differences design to track recovery after Australia's 2019–2020 wildfires. This is the same approach I will use, comparing burned and unburned areas.
 
4. Hawaiian Electric (2023), "Hawaiian Electric begins restoration work in Lahaina at request of Maui Emergency Operations Center" — https://www.hawaiianelectric.com/hawaiian-electric-begins-restoration-work-in-lahaina-at-request-of-maui-emergency-operations-center 
— States that by late August 2023, power was restored to more than 95% of affected Maui customers and to all West Maui customers who could be reconnected. This means that darkness in Lahaina after that point reflects missing buildings and people, not grid outages.
 
 
---
