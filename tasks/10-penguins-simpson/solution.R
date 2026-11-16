ggplot(penguins, aes(x = bill_length_mm, y = bill_depth_mm)) +
  geom_point(aes(colour = species)) +
  geom_smooth(aes(colour = species), method = "lm", se = FALSE) +
  geom_smooth(method = "lm", se = FALSE, colour = "black")
