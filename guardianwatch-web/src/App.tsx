import { Link, NavLink, Navigate, Route, Routes } from "react-router-dom";
import { adminAuth } from "./auth";
import Home from "./pages/Home.tsx";
import ProductDetail from "./pages/ProductDetail.tsx";
import DeviceLookup from "./pages/DeviceLookup.tsx";
import AdminLogin from "./pages/AdminLogin.tsx";
import AdminDashboard from "./pages/AdminDashboard.tsx";

function RequireAdmin({ children }: { children: React.ReactElement }) {
  return adminAuth.getToken() ? children : <Navigate to="/admin/login" replace />;
}

function Header() {
  const navClass = ({ isActive }: { isActive: boolean }) =>
    `text-sm font-medium transition-colors ${
      isActive ? "text-primary" : "text-gray-400 hover:text-gray-200"
    }`;

  return (
    <header className="border-b border-border bg-surface/60 backdrop-blur sticky top-0 z-10">
      <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-3">
        <Link to="/" className="flex items-center gap-2 text-base font-semibold">
          <span className="inline-block h-2 w-2 rounded-full bg-primary" />
          Guardian Watch
        </Link>
        <nav className="flex items-center gap-6">
          <NavLink to="/" className={navClass} end>
            Shop
          </NavLink>
          <NavLink to="/lookup" className={navClass}>
            Look up device
          </NavLink>
          <NavLink to="/admin" className={navClass}>
            Admin
          </NavLink>
        </nav>
      </div>
    </header>
  );
}

export default function App() {
  return (
    <div className="min-h-full flex flex-col">
      <Header />
      <main className="flex-1 mx-auto w-full max-w-6xl px-6 py-8">
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/products/:id" element={<ProductDetail />} />
          <Route path="/lookup" element={<DeviceLookup />} />
          <Route path="/admin/login" element={<AdminLogin />} />
          <Route
            path="/admin"
            element={
              <RequireAdmin>
                <AdminDashboard />
              </RequireAdmin>
            }
          />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
      <footer className="border-t border-border py-6 text-center text-xs text-gray-500">
        Guardian Watch — wellness indicators, not medical diagnoses.
      </footer>
    </div>
  );
}