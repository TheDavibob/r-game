ggplot(penguins, aes(x = flipper_length_mm, y = body_mass_g, colour = species)) +
  geom_point() +
  scale_colour_manual(values = c("darkorange", "purple", "cyan4")) +
  labs(colour = "Species")
