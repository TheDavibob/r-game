known <- penguins[!is.na(penguins$sex), ]

ggplot(known, aes(x = flipper_length_mm, y = body_mass_g, colour = sex)) +
  geom_point() +
  facet_wrap(~species) +
  labs(title = "Male penguins are bigger in every species")
