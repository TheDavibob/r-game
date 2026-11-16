penguins |>
  group_by(species) |>
  summarise(
    n = n(),
    mean_flipper = mean(flipper_length_mm, na.rm = TRUE)
  )
