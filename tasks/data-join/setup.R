# Palmer penguins data (palmerpenguins package, CC0 licence)
penguins <- palmerpenguins::penguins

# A small lookup table of scientific names
species_info <- data.frame(
  species = c("Adelie", "Chinstrap", "Gentoo"),
  latin_name = c("Pygoscelis adeliae", "Pygoscelis antarcticus", "Pygoscelis papua")
)
