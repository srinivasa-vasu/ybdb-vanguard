-- pgvector demo — product catalog with 8-dimensional embeddings
-- Dimensions: [tech, sports, music, health, travel, fashion, gaming, food]

CREATE TABLE products (
  id          SERIAL PRIMARY KEY,
  name        TEXT           NOT NULL,
  category    TEXT           NOT NULL,
  description TEXT           NOT NULL,
  price       NUMERIC(10,2),
  embedding   vector(8)
);

INSERT INTO products (name, category, description, price, embedding) VALUES
  ('Noise-Cancelling Headphones', 'Electronics', 'Premium wireless headphones with active noise cancellation for music and calls', 299.99, '[0.6,0.0,0.9,0.1,0.2,0.2,0.1,0.0]'),
  ('Mechanical Gaming Keyboard',  'Electronics', 'RGB backlit keyboard with tactile switches optimised for gaming performance',  129.99, '[0.7,0.0,0.1,0.0,0.0,0.0,0.9,0.0]'),
  ('Yoga Mat',                    'Sports',      'Non-slip premium mat for yoga, pilates and all fitness levels',                 49.99, '[0.0,0.7,0.0,0.9,0.0,0.2,0.0,0.0]'),
  ('Trail Running Shoes',         'Sports',      'Lightweight shoes with cushioned sole for trail and road running',             119.99, '[0.0,0.9,0.0,0.7,0.2,0.4,0.0,0.0]'),
  ('Smart Watch',                 'Electronics', 'Health tracking smartwatch with GPS, heart rate, and sleep monitoring',        249.99, '[0.7,0.4,0.0,0.8,0.3,0.4,0.2,0.0]'),
  ('Acoustic Guitar Starter Kit', 'Music',       'Beginner acoustic guitar bundle with tuner, picks, and strap',                 89.99, '[0.1,0.0,0.9,0.0,0.0,0.1,0.0,0.0]'),
  ('Portable Bluetooth Speaker',  'Electronics', 'Waterproof speaker for outdoor adventures with 20h battery life',              79.99, '[0.5,0.2,0.8,0.0,0.6,0.0,0.0,0.0]'),
  ('Whey Protein Powder',         'Health',      'Premium whey protein supplement for muscle recovery and growth',               59.99, '[0.0,0.6,0.0,1.0,0.0,0.0,0.0,0.3]'),
  ('40L Travel Backpack',         'Travel',      'Carry-on backpack with laptop compartment and packing cubes',                  89.99, '[0.2,0.3,0.0,0.0,0.9,0.3,0.0,0.0]'),
  ('Wireless Gaming Controller',  'Electronics', 'Ergonomic wireless controller compatible with PC and all major consoles',      69.99, '[0.5,0.0,0.0,0.0,0.0,0.0,1.0,0.0]'),
  ('Waterproof Hiking Boots',     'Sports',      'Sturdy waterproof boots for mountain and technical trail hiking',             149.99, '[0.0,0.7,0.0,0.4,0.8,0.2,0.0,0.0]'),
  ('Vinyl Record Player',         'Music',       'Retro belt-drive turntable with built-in speakers and Bluetooth output',      99.99, '[0.2,0.0,1.0,0.0,0.1,0.3,0.0,0.0]'),
  ('Height-Adjustable Desk',      'Office',      'Electric standing desk with memory presets for ergonomic work setups',       399.99, '[0.4,0.1,0.0,0.3,0.0,0.1,0.2,0.0]'),
  ('Semi-Auto Espresso Machine',  'Kitchen',     'Barista-grade espresso machine with steam wand for home use',                 299.99, '[0.1,0.0,0.0,0.1,0.2,0.2,0.0,0.9]'),
  ('Ultralight Camping Tent',     'Travel',      '4-season ultralight tent for solo backpacking and alpine camping',            189.99, '[0.0,0.5,0.0,0.2,0.9,0.0,0.0,0.0]'),
  ('True Wireless Earbuds',       'Electronics', 'True wireless earbuds with ANC, 24h total battery, and spatial audio',        149.99, '[0.6,0.2,0.8,0.1,0.3,0.3,0.1,0.0]'),
  ('Resistance Bands Set',        'Sports',      'Fabric resistance bands in 5 strengths for strength and rehab training',       29.99, '[0.0,0.8,0.0,0.9,0.0,0.1,0.0,0.0]'),
  ('Piano Lessons Subscription',  'Music',       '1-year access to structured piano lessons from beginner to advanced',          79.99, '[0.2,0.0,0.9,0.2,0.0,0.0,0.0,0.0]'),
  ('Digital Air Fryer',           'Kitchen',     'Compact 5-quart air fryer with 12 presets for quick healthy cooking',          99.99, '[0.1,0.0,0.0,0.4,0.0,0.0,0.0,0.9]'),
  ('Gaming Headset 7.1',          'Electronics', 'Surround-sound gaming headset with noise-cancelling mic for competitive play', 119.99, '[0.5,0.0,0.5,0.0,0.0,0.0,0.9,0.0]');
