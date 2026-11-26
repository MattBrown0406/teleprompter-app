-- Public bucket for the logo shown in Cueframe's emails.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('brand', 'brand', true, 1048576, array['image/png'])
on conflict (id) do nothing;
