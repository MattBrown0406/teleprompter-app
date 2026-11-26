-- Cueframe: private bucket for backed-up footage (takes, imported clips, music, voiceovers, logos).
-- Objects live at <user id>/<path relative to the app's Documents folder>, e.g.
--   3f0c.../Recordings/9A1B....mp4
-- Each user can only touch objects under their own folder.

insert into storage.buckets (id, name, public, file_size_limit)
values ('footage', 'footage', false, null)
on conflict (id) do nothing;

create policy "Users read their own footage" on storage.objects
  for select to authenticated
  using (bucket_id = 'footage' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Users upload their own footage" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'footage' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Users replace their own footage" on storage.objects
  for update to authenticated
  using (bucket_id = 'footage' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'footage' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Users delete their own footage" on storage.objects
  for delete to authenticated
  using (bucket_id = 'footage' and (storage.foldername(name))[1] = (select auth.uid())::text);
