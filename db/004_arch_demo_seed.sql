-- Demo-mode sample data (safe, mainstream history). Re-runnable: wipes and reseeds the
-- three arch_demo_ tables ONLY. Never touches the real arch_titles/keywords/brainstorms.
-- Run as the project owner (e.g. via the Supabase SQL editor / MCP) — the anon key can't delete.
-- Real, well-known documentaries; OCLC/ISBN left blank on purpose (no invented identifiers).

delete from public.arch_demo_titles;
delete from public.arch_demo_keywords;
delete from public.arch_demo_brainstorms;

-- Keywords (24). created_at staggered so newest/oldest sorting looks natural.
insert into public.arch_demo_keywords (term, source, status, created_at) values
('Apollo 11',              'initial list', 'searched',   now() - interval '24 days'),
('Brooklyn Bridge',        'initial list', 'searched',   now() - interval '23 days'),
('Civil Rights Movement',  'initial list', 'searched',   now() - interval '22 days'),
('Civil War',              'initial list', 'searched',   now() - interval '21 days'),
('Dust Bowl',              'initial list', 'searched',   now() - interval '20 days'),
('Lewis and Clark',        'initial list', 'searched',   now() - interval '19 days'),
('Prohibition',            'initial list', 'searched',   now() - interval '18 days'),
('Statue of Liberty',      'initial list', 'searched',   now() - interval '17 days'),
('Panama Canal',           'initial list', 'searched',   now() - interval '16 days'),
('Silk Road',              'initial list', 'searched',   now() - interval '15 days'),
('Marshall Plan',          'initial list', 'unsearched', now() - interval '14 days'),
('Erie Canal',             'initial list', 'unsearched', now() - interval '13 days'),
('Suffrage movement',      'initial list', 'unsearched', now() - interval '12 days'),
('Space Race',             'initial list', 'unsearched', now() - interval '11 days'),
('Transcontinental Railroad','initial list','unsearched', now() - interval '10 days'),
('Hoover Dam',             'initial list', 'unsearched', now() - interval '9 days'),
('Ellis Island',           'initial list', 'unsearched', now() - interval '8 days'),
('Great Depression',       'initial list', 'unsearched', now() - interval '7 days'),
('Industrial Revolution',  'initial list', 'unsearched', now() - interval '6 days'),
('Oregon Trail',           'initial list', 'unsearched', now() - interval '5 days'),
('Gold Rush',              'initial list', 'unsearched', now() - interval '4 days'),
('Roanoke Colony',         'brainstorm: Early American colonies', 'unsearched', now() - interval '3 days'),
('Tennessee Valley Authority','brainstorm: New Deal programs', 'unsearched', now() - interval '2 days'),
('Ancient Rome',           'initial list', 'unsearched', now() - interval '1 day');

-- Titles (8): mix of statuses so the tally, stamps, and title modal all show variety.
insert into public.arch_demo_titles
  (title, year, keywords, route, status, format, creator, date_requested, date_fulfilled, notes, created_at) values
('The Civil War', 1990, 'Civil War', 'UMD', 'fulfilled', 'DVD', 'Ken Burns',
   '2026-08-04', '2026-08-19', null, now() - interval '20 days'),
('Brooklyn Bridge', 1981, 'Brooklyn Bridge', 'ILL', 'requested', 'VHS', 'Ken Burns',
   '2026-09-12', null, 'ILL request placed; older VHS release.', now() - interval '18 days'),
('The Statue of Liberty', 1985, 'Statue of Liberty', 'ILL', 'not_requested', 'VHS', 'Ken Burns',
   null, null, null, now() - interval '16 days'),
('Lewis & Clark: The Journey of the Corps of Discovery', 1997, 'Lewis and Clark', 'UMD', 'fulfilled', 'DVD', 'Ken Burns',
   '2026-08-21', '2026-09-03', null, now() - interval '14 days'),
('Prohibition', 2011, 'Prohibition', 'UMD', 'requested', 'DVD', 'Ken Burns and Lynn Novick',
   '2026-09-22', null, null, now() - interval '12 days'),
('The Dust Bowl', 2012, 'Dust Bowl', 'UMD', 'not_requested', 'DVD', 'Ken Burns',
   null, null, null, now() - interval '10 days'),
('Apollo 11', 2019, 'Apollo 11', 'UMD', 'fulfilled', 'DVD', 'Todd Douglas Miller',
   '2026-09-01', '2026-09-10', null, now() - interval '8 days'),
('Eyes on the Prize', 1987, 'Civil Rights Movement', 'ILL', 'unavailable', 'VHS', 'Henry Hampton / Blackside',
   '2026-08-28', null, 'Marked unavailable after first ILL attempt; retry with an alternate edition.', now() - interval '6 days');
