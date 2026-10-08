/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  theme: {
    extend: {
      colors: {
        bg: "#0a0e1a",
        surface: "#141827",
        surfaceHi: "#1c2136",
        border: "#232937",
        primary: "#00B4D8",
        primaryHover: "#0096b8",
        secondary: "#0077B6",
        danger: "#E63946",
      },
      fontFamily: {
        sans: [
          "system-ui",
          "-apple-system",
          "Segoe UI",
          "Roboto",
          "Helvetica Neue",
          "sans-serif",
        ],
      },
    },
  },
  plugins: [],
};