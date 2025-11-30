import React from 'react';
import { Routes, Route } from 'react-router-dom';
import Home from './pages/Home';
import MatcherGuide from './pages/MatcherGuide';
import './App.css';
import './pages/MatcherGuide.css';

export default function App() {
  return (
    <Routes>
      <Route path="/" element={<Home />} />
      <Route path="/matcher-guide" element={<MatcherGuide />} />
    </Routes>
  );
}
