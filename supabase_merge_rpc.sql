-- Automatic overlap merge RPC for public LNG submissions.
-- Applied to Supabase as migration: add_safe_lng_merge_rpc_v2
-- The function intentionally accepts anonymous submissions and only merges/inserts LNG entries.
create sequence if not exists public.lng_entry_id_seq;
select setval('public.lng_entry_id_seq', coalesce((select max((substring(id from 5))::bigint) from public.lng_entries where id ~ '^LNG-[0-9]+
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_id text := coalesce(p_entry->>'id','');
  v_s text := coalesce(p_entry->>'s','user');
  v_t text := btrim(coalesce(p_entry->>'t',''));
  v_p text := btrim(coalesce(p_entry->>'p','待確認'));
  v_d text := btrim(coalesce(p_entry->>'d','待確認'));
  v_time text := btrim(coalesce(p_entry->>'time','待確認'));
  v_note text := btrim(coalesce(p_entry->>'note',''));
  v_k jsonb := case when jsonb_typeof(p_entry->'k')='array' then p_entry->'k' else '[]'::jsonb end;
  v_links jsonb := case when jsonb_typeof(p_entry->'links')='array' then p_entry->'links' else '[]'::jsonb end;
  v_target public.lng_entries%rowtype;
  v_score integer := 0;
  v_merged_k jsonb;
  v_merged_links jsonb;
  v_insert_id text;
begin
  if v_t = '' or length(v_t) > 500 then raise exception 'invalid title'; end if;
  if jsonb_array_length(v_k) > 50 or jsonb_array_length(v_links) > 20 then raise exception 'too many keywords or links'; end if;
  if v_s not in ('user','community','pending') then v_s := 'user'; end if;

  select e into v_target
  from public.lng_entries e
  where
    exists (
      select 1 from jsonb_array_elements(v_links) nl
      where jsonb_typeof(nl)='array' and jsonb_array_length(nl)>=2
        and exists (
          select 1 from jsonb_array_elements(e.links) ol
          where jsonb_typeof(ol)='array' and jsonb_array_length(ol)>=2 and nl->>1=ol->>1
        )
    )
    or lower(regexp_replace(coalesce(e.t,''),'[^[:alnum:]一-龥]+','','g'))=lower(regexp_replace(v_t,'[^[:alnum:]一-龥]+','','g'))
    or exists (
      select 1 from jsonb_array_elements_text(v_k) nk
      where exists (
        select 1 from jsonb_array_elements_text(e.k) ek
        where lower(regexp_replace(nk,'[^[:alnum:]一-龥]+','','g'))=lower(regexp_replace(ek,'[^[:alnum:]一-龥]+','','g'))
      )
    )
    or (
      length(v_t)>=4
      and (
        lower(regexp_replace(coalesce(e.t,''),'[^[:alnum:]一-龥]+','','g')) like '%'||lower(regexp_replace(v_t,'[^[:alnum:]一-龥]+','','g'))||'%'
        or lower(regexp_replace(v_t,'[^[:alnum:]一-龥]+','','g')) like '%'||lower(regexp_replace(coalesce(e.t,''),'[^[:alnum:]一-龥]+','','g'))||'%'
      )
    )
  order by
    case when exists (
      select 1 from jsonb_array_elements(v_links) nl
      where jsonb_typeof(nl)='array' and jsonb_array_length(nl)>=2
        and exists (select 1 from jsonb_array_elements(e.links) ol where jsonb_typeof(ol)='array' and jsonb_array_length(ol)>=2 and nl->>1=ol->>1)
    ) then 100 else 0 end desc,
    case when lower(regexp_replace(coalesce(e.t,''),'[^[:alnum:]一-龥]+','','g'))=lower(regexp_replace(v_t,'[^[:alnum:]一-龥]+','','g')) then 80 else 0 end desc,
    e.created_at asc
  limit 1;

  if v_target.id is null then
    v_insert_id := 'LNG-'||nextval('public.lng_entry_id_seq')::text;
    insert into public.lng_entries(id,s,t,k,p,d,time,note,links)
    values(v_insert_id,v_s,v_t,v_k,v_p,v_d,v_time,v_note,v_links);
    return jsonb_build_object('action','inserted','id',v_insert_id);
  end if;

  if v_target.s='confirmed' then v_score:=100; else v_score:=50; end if;

  select coalesce(jsonb_agg(to_jsonb(z.val) order by z.ord),'[]'::jsonb) into v_merged_k
  from (
    select val,min(ord) ord
    from (
      select jsonb_array_elements_text(v_target.k) val,1 ord
      union all select jsonb_array_elements_text(v_k) val,2 ord
    ) u
    group by lower(val),val
  ) z;

  select coalesce(jsonb_agg(z.val order by z.ord),'[]'::jsonb) into v_merged_links
  from (
    select val,min(ord) ord
    from (
      select jsonb_array_elements(v_target.links) val,1 ord
      union all select jsonb_array_elements(v_links) val,2 ord
    ) u
    group by val
  ) z;

  update public.lng_entries
  set
    t=case when v_target.s='confirmed' then v_target.t when length(v_t)>length(v_target.t) then v_t else v_target.t end,
    s=case when v_target.s='confirmed' then 'confirmed' when v_s='community' then 'community' else v_target.s end,
    k=v_merged_k,
    p=case when v_target.p is null or v_target.p in ('','待確認','待定位','待考古') then v_p when v_p in ('','待確認','待定位','待考古') or v_p=v_target.p then v_target.p else v_target.p||'／'||v_p end,
    d=case when v_target.d in ('','待確認','待定位','待考古') then v_d else v_target.d end,
    time=case when v_target.time in ('','待確認','待定位','待驗證','待逐秒驗證') and v_time not in ('','待確認','待定位','待驗證','待逐秒驗證') then v_time else v_target.time end,
    note=case when v_note='' then v_target.note when v_target.note='' then v_note when position(v_note in v_target.note)>0 then v_target.note else v_target.note||'｜整合回報：'||v_note end,
    links=v_merged_links
  where id=v_target.id;

  return jsonb_build_object('action','merged','id',v_target.id,'match_score',v_score);
end;
$$;

revoke all on function public.merge_lng_entry(jsonb) from public;
grant execute on function public.merge_lng_entry(jsonb) to anon, authenticated;
),0), true);

create or replace function public.merge_lng_entry(p_entry jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_id text := coalesce(p_entry->>'id','');
  v_s text := coalesce(p_entry->>'s','user');
  v_t text := btrim(coalesce(p_entry->>'t',''));
  v_p text := btrim(coalesce(p_entry->>'p','待確認'));
  v_d text := btrim(coalesce(p_entry->>'d','待確認'));
  v_time text := btrim(coalesce(p_entry->>'time','待確認'));
  v_note text := btrim(coalesce(p_entry->>'note',''));
  v_k jsonb := case when jsonb_typeof(p_entry->'k')='array' then p_entry->'k' else '[]'::jsonb end;
  v_links jsonb := case when jsonb_typeof(p_entry->'links')='array' then p_entry->'links' else '[]'::jsonb end;
  v_target public.lng_entries%rowtype;
  v_score integer := 0;
  v_merged_k jsonb;
  v_merged_links jsonb;
  v_insert_id text;
begin
  if v_t = '' or length(v_t) > 500 then raise exception 'invalid title'; end if;
  if jsonb_array_length(v_k) > 50 or jsonb_array_length(v_links) > 20 then raise exception 'too many keywords or links'; end if;
  if v_s not in ('user','community','pending') then v_s := 'user'; end if;

  select e into v_target
  from public.lng_entries e
  where
    exists (
      select 1 from jsonb_array_elements(v_links) nl
      where jsonb_typeof(nl)='array' and jsonb_array_length(nl)>=2
        and exists (
          select 1 from jsonb_array_elements(e.links) ol
          where jsonb_typeof(ol)='array' and jsonb_array_length(ol)>=2 and nl->>1=ol->>1
        )
    )
    or lower(regexp_replace(coalesce(e.t,''),'[^[:alnum:]一-龥]+','','g'))=lower(regexp_replace(v_t,'[^[:alnum:]一-龥]+','','g'))
    or exists (
      select 1 from jsonb_array_elements_text(v_k) nk
      where exists (
        select 1 from jsonb_array_elements_text(e.k) ek
        where lower(regexp_replace(nk,'[^[:alnum:]一-龥]+','','g'))=lower(regexp_replace(ek,'[^[:alnum:]一-龥]+','','g'))
      )
    )
    or (
      length(v_t)>=4
      and (
        lower(regexp_replace(coalesce(e.t,''),'[^[:alnum:]一-龥]+','','g')) like '%'||lower(regexp_replace(v_t,'[^[:alnum:]一-龥]+','','g'))||'%'
        or lower(regexp_replace(v_t,'[^[:alnum:]一-龥]+','','g')) like '%'||lower(regexp_replace(coalesce(e.t,''),'[^[:alnum:]一-龥]+','','g'))||'%'
      )
    )
  order by
    case when exists (
      select 1 from jsonb_array_elements(v_links) nl
      where jsonb_typeof(nl)='array' and jsonb_array_length(nl)>=2
        and exists (select 1 from jsonb_array_elements(e.links) ol where jsonb_typeof(ol)='array' and jsonb_array_length(ol)>=2 and nl->>1=ol->>1)
    ) then 100 else 0 end desc,
    case when lower(regexp_replace(coalesce(e.t,''),'[^[:alnum:]一-龥]+','','g'))=lower(regexp_replace(v_t,'[^[:alnum:]一-龥]+','','g')) then 80 else 0 end desc,
    e.created_at asc
  limit 1;

  if v_target.id is null then
    v_insert_id := case when v_id<>'' then v_id else 'LNG-U'||right(extract(epoch from clock_timestamp())::bigint::text,8) end;
    insert into public.lng_entries(id,s,t,k,p,d,time,note,links)
    values(v_insert_id,v_s,v_t,v_k,v_p,v_d,v_time,v_note,v_links);
    return jsonb_build_object('action','inserted','id',v_insert_id);
  end if;

  if v_target.s='confirmed' then v_score:=100; else v_score:=50; end if;

  select coalesce(jsonb_agg(to_jsonb(z.val) order by z.ord),'[]'::jsonb) into v_merged_k
  from (
    select val,min(ord) ord
    from (
      select jsonb_array_elements_text(v_target.k) val,1 ord
      union all select jsonb_array_elements_text(v_k) val,2 ord
    ) u
    group by lower(val),val
  ) z;

  select coalesce(jsonb_agg(z.val order by z.ord),'[]'::jsonb) into v_merged_links
  from (
    select val,min(ord) ord
    from (
      select jsonb_array_elements(v_target.links) val,1 ord
      union all select jsonb_array_elements(v_links) val,2 ord
    ) u
    group by val
  ) z;

  update public.lng_entries
  set
    t=case when v_target.s='confirmed' then v_target.t when length(v_t)>length(v_target.t) then v_t else v_target.t end,
    s=case when v_target.s='confirmed' then 'confirmed' when v_s='community' then 'community' else v_target.s end,
    k=v_merged_k,
    p=case when v_target.p is null or v_target.p in ('','待確認','待定位','待考古') then v_p when v_p in ('','待確認','待定位','待考古') or v_p=v_target.p then v_target.p else v_target.p||'／'||v_p end,
    d=case when v_target.d in ('','待確認','待定位','待考古') then v_d else v_target.d end,
    time=case when v_target.time in ('','待確認','待定位','待驗證','待逐秒驗證') and v_time not in ('','待確認','待定位','待驗證','待逐秒驗證') then v_time else v_target.time end,
    note=case when v_note='' then v_target.note when v_target.note='' then v_note when position(v_note in v_target.note)>0 then v_target.note else v_target.note||'｜整合回報：'||v_note end,
    links=v_merged_links
  where id=v_target.id;

  return jsonb_build_object('action','merged','id',v_target.id,'match_score',v_score);
end;
$$;

revoke all on function public.merge_lng_entry(jsonb) from public;
grant execute on function public.merge_lng_entry(jsonb) to anon, authenticated;
