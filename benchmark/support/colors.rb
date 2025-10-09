# frozen_string_literal: true

# Colorization utilities for benchmark output
module Colors
  RESET = "\033[0m"
  BOLD = "\033[1m"
  DIM = "\033[2m"

  # Text colors
  RED = "\033[31m"
  GREEN = "\033[32m"
  YELLOW = "\033[33m"
  BLUE = "\033[34m"
  MAGENTA = "\033[35m"
  CYAN = "\033[36m"
  WHITE = "\033[37m"

  # Background colors
  BG_RED = "\033[41m"
  BG_GREEN = "\033[42m"
  BG_YELLOW = "\033[43m"
  BG_BLUE = "\033[44m"

  def self.colorize(text, color)
    "#{color}#{text}#{RESET}"
  end

  def self.bold(text)
    colorize(text, BOLD)
  end

  def self.dim(text)
    colorize(text, DIM)
  end

  def self.success(text)
    colorize(text, GREEN)
  end

  def self.warning(text)
    colorize(text, YELLOW)
  end

  def self.error(text)
    colorize(text, RED)
  end

  def self.info(text)
    colorize(text, CYAN)
  end

  def self.highlight(text)
    colorize(text, MAGENTA)
  end
end
