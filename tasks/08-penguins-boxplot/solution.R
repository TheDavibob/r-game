ggplot(penguins, aes(x = species, y = body_mass_g)) +
  geom_boxplot() +
  labs(
    title = "Gentoo penguins are the heaviest",
    x = "Species",
    y = "Body mass (g)"
  )
