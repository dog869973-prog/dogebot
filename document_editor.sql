-- Run once in the existing Supabase SQL Editor. Retains existing document rows.
begin;
alter table public.bot_documents add column if not exists content jsonb;
alter table public.bot_documents add column if not exists updated_at timestamptz default now();
alter table public.bot_documents add column if not exists editor_revision bigint not null default 0;
create or replace function public.doge_document_save(p_document_id text, p_content jsonb, p_revision bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d public.bot_documents%rowtype; discord_id text;
begin
 if auth.uid() is null then raise exception '로그인이 필요해요.'; end if;
 select i.provider_id into discord_id from auth.identities i where i.user_id=auth.uid() and i.provider='discord' limit 1;
 if discord_id is null then raise exception '디스코드 인증이 필요해요.'; end if;
 select * into d from public.bot_documents where id::text=p_document_id for update;
 if not found then raise exception '문서를 찾을 수 없어요.'; end if;
 if d.author_id::text is distinct from discord_id and not exists(select 1 from public.bot_document_permissions p where p.document_id=d.id and p.user_id::text=discord_id and p.role='editor') then raise exception '편집 권한이 없어요.'; end if;
 if d.editor_revision is distinct from p_revision then raise exception 'DOGE_DOCUMENT_CONFLICT'; end if;
 if p_content is null or jsonb_typeof(p_content)<>'object' or octet_length(p_content::text)>10485760 then raise exception '문서 데이터는 최대 10MB예요.'; end if;
 if (d.doc_type='hwp' and jsonb_typeof(p_content->'ops') is distinct from 'array') or (d.doc_type='excel' and (p_content->>'kind' is distinct from 'excel' or jsonb_typeof(p_content->'sheets') is distinct from 'array')) or (d.doc_type='ppt' and (p_content->>'kind' is distinct from 'ppt' or jsonb_typeof(p_content->'slides') is distinct from 'array')) then raise exception '문서 형식이 올바르지 않아요.'; end if;
 update public.bot_documents set content=p_content,updated_at=now(),editor_revision=editor_revision+1 where id=d.id;
 return jsonb_build_object('editor_revision',d.editor_revision+1);
end $$;
revoke all on function public.doge_document_save(text,jsonb,bigint) from public,anon;
grant execute on function public.doge_document_save(text,jsonb,bigint) to authenticated;
-- Track writes made by previous clients as well, so they invalidate stale revisions.
create or replace function public.doge_document_revision_guard() returns trigger language plpgsql set search_path='' as $$
begin
 if new.content is distinct from old.content and new.editor_revision=old.editor_revision then new.editor_revision=old.editor_revision+1; end if;
 return new;
end $$;
drop trigger if exists doge_document_revision_guard on public.bot_documents;
create trigger doge_document_revision_guard before update on public.bot_documents for each row execute function public.doge_document_revision_guard();
commit;
