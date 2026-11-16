ggplot(mtcars, aes(x = wt, y = mpg, colour = factor(cyl))) +
  geom_point() +
  labs(title = "Heavier cars use more fuel")
