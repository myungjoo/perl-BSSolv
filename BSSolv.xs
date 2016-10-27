#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define MULTI_SEMANTICS

#include "pool.h"
#include "repo.h"
#include "util.h"
#include "evr.h"
#include "hash.h"
#include "chksum.h"
#include "repo_solv.h"
#include "repo_write.h"
#include "repo_rpmdb.h"
#include "repo_deb.h"
#if 1
#include "repo_arch.h"
#endif

typedef struct _Expander {
  Pool *pool;

  Map ignored;
  Map ignoredx;

  Queue preferposq;
  Map preferpos;
  Map preferposx;

  Map preferneg;
  Map prefernegx;

  Queue conflictsq;
  Map conflicts;

  int debug;
  int havefileprovides;
  int ignoreconflicts;
  int ignoreignore;

  char *debugstr;
  int debugstrl;
  int debugstrf;
} Expander;

typedef Pool *BSSolv__pool;
typedef Repo *BSSolv__repo;
typedef Expander *BSSolv__expander;

static Id buildservice_id;
static Id buildservice_repocookie;
static Id buildservice_external;
static Id buildservice_dodurl;
static Id expander_directdepsend;
static Id buildservice_dodcookie;

/* make sure bit n is usable */
#define MAPEXP(m, n) ((m)->size < (((n) + 8) >> 3) ? map_grow(m, n + 256) : 0)

#define REPOCOOKIE "buildservice repo 1.1"

static int
myrepowritefilter(Repo *repo, Repokey *key, void *kfdata)
{
  int i;
  if (key->name == SOLVABLE_URL)
    return KEY_STORAGE_DROPPED;
  if (key->name == SOLVABLE_HEADEREND)
    return KEY_STORAGE_DROPPED;
  if (key->name == SOLVABLE_PACKAGER)
    return KEY_STORAGE_DROPPED;
  if (key->name == SOLVABLE_GROUP)
    return KEY_STORAGE_DROPPED;
  if (key->name == SOLVABLE_LICENSE)
    return KEY_STORAGE_DROPPED;
  if (key->name == SOLVABLE_PKGID)
    return KEY_STORAGE_INCORE;
  if (key->name == SOLVABLE_CHECKSUM)
    return KEY_STORAGE_INCORE;
  i = repo_write_stdkeyfilter(repo, key, kfdata);
  if (i == KEY_STORAGE_VERTICAL_OFFSET)
    return KEY_STORAGE_DROPPED;
  return i;
}

static inline char *
hvlookupstr(HV *hv, const char *key, int keyl)
{
  SV **svp = hv_fetch(hv, key, keyl, 0);
  if (!svp)
    return 0;
  return SvPV_nolen(*svp);
}

static inline AV *
hvlookupav(HV *hv, const char *key, int keyl)
{
  SV *sv, **svp = hv_fetch(hv, key, keyl, 0);
  if (!svp)
    return 0;
  sv = *svp;
  if (!sv || !SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVAV)
    return 0;
  return (AV *)SvRV(sv);
}

static Id
makeevr(Pool *pool, char *e, char *v, char *r)
{
  char *s;

  if (!v)
    return 0;
  if (e && !strcmp(e, "0"))
    e = 0;
  if (e)
    s = pool_tmpjoin(pool, e, ":", v);
  else
    s = v;
  if (r)
    s = pool_tmpjoin(pool, s, "-", r);
  return pool_str2id(pool, s, 1);
}

static inline char *
avlookupstr(AV *av, int n)
{
  SV **svp = av_fetch(av, n, 0);
  if (!svp)
    return 0;
  return SvPV_nolen(*svp);
}

static inline Id
id2name(Pool *pool, Id id)
{
  while (ISRELDEP(id))
    {
      Reldep *rd = GETRELDEP(pool, id);
      id = rd->name;
    }
  return id;
}

static Id
dep2id(Pool *pool, char *s)
{
  char *n;
  Id id;
  int flags;

  if ((n = strchr(s, '|')) != 0)
    {
      id = dep2id(pool, n + 1);
      *n = 0;
      id = pool_rel2id(pool, dep2id(pool, s), id, REL_OR, 1);
      *n = '|';
      return id;
    }
  while (*s == ' ' || *s == '\t')
    s++;
  n = s;
  while (*s && *s != ' ' && *s != '\t' && *s != '<' && *s != '=' && *s != '>')
    s++;
#ifdef REL_MULTIARCH
  if (s - n > 4 && s[-4] == ':' && !strncmp(s - 4, ":any", 4))
    {
      id = pool_strn2id(pool, n, s - n - 4, 1);
      id = pool_rel2id(pool, id, ARCH_ANY, REL_MULTIARCH, 1);
    }
  else
#endif
    id = pool_strn2id(pool, n, s - n, 1);
  if (!*s)
    return id;
  while (*s == ' ' || *s == '\t')
    s++;
  flags = 0;
  for (;;s++)
    {
      if (*s == '<')
	flags |= REL_LT;
      else if (*s == '=')
	flags |= REL_EQ;
      else if (*s == '>')
	flags |= REL_GT;
      else
	break;
    }
  if (!flags)
    return id;
  while (*s == ' ' || *s == '\t')
    s++;
  n = s;
  while (*s && *s != ' ' && *s != '\t')
    s++;
  return pool_rel2id(pool, id, pool_strn2id(pool, n, s - n, 1), flags, 1);
}

static inline Offset
importdeps(HV *hv, const char *key, int keyl, Repo *repo)
{
  Pool *pool = repo->pool;
  int i;
  AV *av = hvlookupav(hv, key, keyl);
  Offset off = 0;
  if (av)
    {
      for (i = 0; i <= av_len(av); i++)
	{
	  char *str = avlookupstr(av, i);
	  if (str)
	    off = repo_addid_dep(repo, off, dep2id(pool, str), 0);
	}
    }
  return off;
}

void
exportdeps(HV *hv, const char *key, int keyl, Repo *repo, Offset off, Id skey)
{
  Pool *pool = repo->pool;
  AV *av;
  Id id, *pp;
  const char *str;

  if (!off || !repo->idarraydata[off])
    return;
  pp = repo->idarraydata + off;
  av = 0;
  while ((id = *pp++))
    {
      if (id == SOLVABLE_FILEMARKER)
	break;
      str = pool_dep2str(pool, id);
      if (ISRELDEP(id))
	{
	  Reldep *rd = GETRELDEP(pool, id);
	  if (skey == SOLVABLE_CONFLICTS && rd->flags == REL_NAMESPACE && rd->name == NAMESPACE_OTHERPROVIDERS)
	    {
	    if (!strncmp(str, "namespace:", 10))
	      str += 10;
	    }
	  if (skey == SOLVABLE_SUPPLEMENTS)
	    {
	      if (rd->flags == REL_NAMESPACE && rd->name == NAMESPACE_FILESYSTEM)
		{
		  if (!strncmp(str, "namespace:", 10))
		    str += 10;
		}
	      else if (rd->flags == REL_NAMESPACE && rd->name == NAMESPACE_MODALIAS)
		{
		  if (!strncmp(str, "namespace:", 10))
		    str += 10;
		}
	      else if (rd->flags == REL_AND)
		{
		  /* either packageand chain or modalias */
		  str = 0;
		  if (ISRELDEP(rd->evr))
		    {
		      Reldep *mrd = GETRELDEP(pool, rd->evr);
		      if (mrd->flags == REL_NAMESPACE && mrd->name == NAMESPACE_MODALIAS)
			{
			  str = pool_tmpjoin(pool, "modalias(", pool_dep2str(pool, rd->name), ":");
			  str = pool_tmpappend(pool, str, pool_dep2str(pool, mrd->evr), ")");
			}
		      else if (mrd->flags >= 8)
			continue;
		    }
		  if (!str)
		    {
		      /* must be and chain */
		      str = pool_dep2str(pool, rd->evr);
		      for (;;)
			{
			  id = rd->name;
			  if (!ISRELDEP(id))
			    break;
			  rd = GETRELDEP(pool, id);
			  if (rd->flags != REL_AND)
			    break;
			  str = pool_tmpjoin(pool, pool_dep2str(pool, rd->evr), ":", str);
			}
		      str = pool_tmpjoin(pool, pool_dep2str(pool, id), ":", str);
		      str = pool_tmpjoin(pool, "packageand(", str, ")");
		    }
		}
	      else if (rd->flags >= 8)
		continue;
	    }
	}
      if (skey == SOLVABLE_REQUIRES)
	{
	  if (id == SOLVABLE_PREREQMARKER)
	    continue;
	  if (*str == 'r' && !strncmp(str, "rpmlib(", 7))
	    continue;
	}
      if (!av)
        av = newAV();
      av_push(av, newSVpv(str, 0));
    }
  if (av)
    (void)hv_store(hv, key, keyl, newRV_noinc((SV*)av), 0);
}

void
data2solvables(Repo *repo, Repodata *data, HV *rhv)
{
  Pool *pool = repo->pool;
  SV *sv;
  HV *hv;
  char *str, *key;
  I32 keyl;
  Id p;
  Solvable *s;

  hv_iterinit(rhv);
  while ((sv = hv_iternextsv(rhv, &key, &keyl)) != 0)
    {
      if (!SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVHV)
	continue;
      hv = (HV *)SvRV(sv);
      str = hvlookupstr(hv, "name", 4);
      if (!str)
	continue;	/* need to have a name */
      p = repo_add_solvable(repo);
      s = pool_id2solvable(pool, p);
      s->name = pool_str2id(pool, str, 1);
      str = hvlookupstr(hv, "arch", 4);
      if (!str)
	str = "";	/* dummy, need to have arch */
      s->arch = pool_str2id(pool, str, 1);
      s->evr = makeevr(pool, hvlookupstr(hv, "epoch", 5), hvlookupstr(hv, "version", 7), hvlookupstr(hv, "release", 7));
      str = hvlookupstr(hv, "path", 4);
      if (str)
	{
	  char *ss = strrchr(str, '/');
	  if (ss)
	    {
	      *ss = 0;
	      repodata_set_str(data, p, SOLVABLE_MEDIADIR, str);
	      *ss++ = '/';
	    }
	  else
	    ss = str;
	  repodata_set_str(data, p, SOLVABLE_MEDIAFILE, ss);
	}
      str = hvlookupstr(hv, "id", 2);
      if (str)
	repodata_set_str(data, p, buildservice_id, str);
      str = hvlookupstr(hv, "source", 6);
      if (str)
	repodata_set_poolstr(data, p, SOLVABLE_SOURCENAME, str);
      str = hvlookupstr(hv, "hdrmd5", 6);
      if (str && strlen(str) == 32)
	repodata_set_checksum(data, p, SOLVABLE_PKGID, REPOKEY_TYPE_MD5, str);
      s->provides    = importdeps(hv, "provides", 8, repo);
      s->obsoletes   = importdeps(hv, "obsoletes", 9, repo);
      s->conflicts   = importdeps(hv, "conflicts", 9, repo);
      s->requires    = importdeps(hv, "requires", 8, repo);
      s->recommends  = importdeps(hv, "recommends", 10, repo);
      s->suggests    = importdeps(hv, "suggests", 8, repo);
      s->supplements = importdeps(hv, "supplements", 11, repo);
      s->enhances    = importdeps(hv, "enhances", 8, repo);
      if (!s->evr && s->provides)
	{
	  /* look for self provides */
	  Id pro, *prop = s->repo->idarraydata + s->provides;
	  while ((pro = *prop++) != 0)
	    {
	      Reldep *rd;
	      if (!ISRELDEP(pro))
		continue;
	      rd = GETRELDEP(pool, pro);
	      if (rd->name == s->name && rd->flags == REL_EQ)
		s->evr = rd->evr;
	    }
	}
      if (s->evr)
	s->provides = repo_addid_dep(repo, s->provides, pool_rel2id(pool, s->name, s->evr, REL_EQ, 1), 0);
      str = hvlookupstr(hv, "checksum", 8);
      if (str)
	{
	  char *cp, typebuf[8];
	  Id ctype;
	  if (*str != ':' && (cp = strchr(str, ':')) != 0 && cp - str < sizeof(typebuf))
	    {
	      strncpy(typebuf, str, cp - str);
	      typebuf[cp - str] = 0;
	      ctype = solv_chksum_str2type(typebuf);
	      if (ctype)
		repodata_set_checksum(data, p, SOLVABLE_CHECKSUM, ctype, cp + 1);
	    }
	}
    }

  repodata_set_str(data, SOLVID_META, buildservice_repocookie, REPOCOOKIE);
  str = hvlookupstr(rhv, "/url", 4);
  if (str)
    repodata_set_str(data, SOLVID_META, buildservice_dodurl, str);
  str = hvlookupstr(rhv, "/dodcookie", 10);
  if (str)
    repodata_set_str(data, SOLVID_META, buildservice_dodcookie, str);
}

static SV *
retrieve(unsigned char **srcp, STRLEN *srclp, int depth)
{
  SV *sv, *rv;
  AV *av;
  HV *hv;
  unsigned char *src = *srcp;
  STRLEN srcl = *srclp;
  int type;
  unsigned int i, len;
  STRLEN size;

  if (depth > 10)
    return 0;
  if (srcl-- == 0)
    return 0;
  type = *src++;
  switch (type)
    {
    case 1:
      if (srcl < 4)
	return 0;
      size = src[0] << 24 | src[1] << 16 | src[2] << 8 | src[3];
      srcl -= 4;
      src += 4;
      if (srcl < size)
	return 0;
      sv = NEWSV(10002, size);
      sv_setpvn(sv, (char *)src, size);
      srcl -= size;
      src += size;
      break;
    case 2:
      if (srcl < 4)
	return 0;
      len = src[0] << 24 | src[1] << 16 | src[2] << 8 | src[3];
      srcl -= 4;
      src += 4;
      if (len > srcl)
	return 0;
      av = newAV();
      if (len)
	av_extend(av, len);
      for (i = 0; i < len; i++)
	{
	  sv = retrieve(&src, &srcl, depth + 1);
	  if (!sv)
	    return 0;
	  if (av_store(av, i, sv) == 0)
	    return 0;
	}
      sv = (SV *)av;
      break;
    case 3:
      if (srcl < 4)
	return 0;
      len = src[0] << 24 | src[1] << 16 | src[2] << 8 | src[3];
      srcl -= 4;
      src += 4;
      if (len > srcl)
	return 0;
      hv = newHV();
      if (len)
	hv_ksplit(hv, len + 1);
      for (i = 0; i < len; i++)
	{
	  sv = retrieve(&src, &srcl, depth + 1);
	  if (!sv) 
	    return 0;
	  if (srcl < 4)
	    return 0;
	  size = src[0] << 24 | src[1] << 16 | src[2] << 8 | src[3];
	  srcl -= 4;
	  src += 4;
	  if (srcl < size)
	    return 0;
          if (hv_store(hv, (char *)src, (U32)size, sv, 0) == 0)
	    return 0;
	  srcl -= size;
	  src += size;
	}
      sv = (SV *)hv;
      break;
    case 4:
      rv = NEWSV(10002, 0);
      sv = retrieve(&src, &srcl, depth + 1);
      if (!sv) 
	return 0;
      sv_upgrade(rv, SVt_RV);
      SvRV_set(rv, sv);
      SvROK_on(rv);
      sv = rv;
      break;
    case 10:
      if (srcl-- == 0)
	return 0;
      size = *src++;
      if (srcl < size)
	return 0;
      sv = NEWSV(10002, size);
      sv_setpvn(sv, (char *)src, size);
      srcl -= size;
      src += size;
      break;
    default:
      /* fprintf(stderr, "unknown tag %d\n", type); */
      return 0;
    }
  *srcp = src;
  *srclp = srcl;
  return sv;
}

static void
expander_dbg(Expander *xp, const char *format, ...)
{
  va_list args;
  char buf[1024];
  int l;
  if (!xp->debug)
    return;
  va_start(args, format);
  vsnprintf(buf, sizeof(buf), format, args);
  va_end(args);
  printf("%s", buf);
  l = strlen(buf);
  if (buf[0] != ' ' || (l && buf[l - 1] == '\n'))
    fflush(stdout);
  if (l >= xp->debugstrf)	/* >= because of trailing \0 */
    {
      xp->debugstr = solv_realloc(xp->debugstr, xp->debugstrl + l + 1024);
      xp->debugstrf = l + 1024;
    }
  strcpy(xp->debugstr + xp->debugstrl, buf);
  xp->debugstrl += l;
  xp->debugstrf -= l;
}

static const char *
expander_solvid2name(Expander *xp, Id p)
{
  const char *n = pool_id2str(xp->pool, xp->pool->solvables[p].name);
  Repo *r; 
  if (!xp->debug)
    return n;
  r = xp->pool->solvables[p].repo;
  if (!r) 
    return n;
  return pool_tmpjoin(xp->pool, n, "@", r->name);
}

static inline void
expander_installed(Expander *xp, Id p, Map *installed, Map *conflicts, Queue *conflictsinfo, int *cidone, Queue *out, Queue *todo)
{
  Pool *pool = xp->pool;
  Solvable *s = pool->solvables + p;
  Id req, id, *reqp, con, *conp;
  const char *n;

  MAPSET(installed, p);
  queue_push(out, p);
  if (MAPTST(&xp->conflicts, s->name))
    {
      int i;
      for (i = 0; i < xp->conflictsq.count; i++)
	{
	  Id p2, pp2;
	  Id id = xp->conflictsq.elements[i];
	  if (id != s->name)
	    continue;
	  id = xp->conflictsq.elements[i ^ 1];
	  FOR_PROVIDES(p2, pp2, id)
	    {
	      if (pool->solvables[p2].name == id)
		{
		  MAPEXP(conflicts, pool->nsolvables);
	          MAPSET(conflicts, p2);
		}
	    }
	}
    }
  if (s->requires)
    {
      reqp = s->repo->idarraydata + s->requires;
      while ((req = *reqp++) != 0)
	{
	  if (req == SOLVABLE_PREREQMARKER)
	    continue;
	  id = id2name(pool, req);
	  if (!xp->ignoreignore)
	    {
	      if (MAPTST(&xp->ignored, id))
		continue;
	      if (MAPTST(&xp->ignoredx, id))
		{
		  Id xid = pool_str2id(pool, pool_tmpjoin(pool, pool_id2str(pool, s->name), ":", pool_id2str(pool, id)), 0);
		  if (xid && MAPTST(&xp->ignored, xid))
		    continue;
		}
	    }
	  n = pool_id2str(pool, id);
	  if (!strncmp(n, "rpmlib(", 7))
	    {
	      MAPEXP(&xp->ignored, id);
	      MAPSET(&xp->ignored, id);
	      continue;
	    }
	  if (*n == '/')
	    {
	      if (!xp->havefileprovides || pool->whatprovides[id] <= 1)
		{
		  MAPEXP(&xp->ignored, id);
		  MAPSET(&xp->ignored, id);
		  continue;
		}
	    }
	  queue_push2(todo, req, p);
	}
    }
  if (!xp->ignoreconflicts)
    {
      if (s->conflicts)
	{
	  conp = s->repo->idarraydata + s->conflicts;
	  while ((con = *conp++) != 0)
	    {
	      Id p2, pp2;
	      FOR_PROVIDES(p2, pp2, con)
		{
		  if (p2 == p)
		    continue;
		  MAPEXP(conflicts, pool->nsolvables);
		  MAPSET(conflicts, p2);
		  if (xp->debug)
		    queue_push2(conflictsinfo, p2, p);
		}
	    }
	}
      if (s->obsoletes)
	{
	  conp = s->repo->idarraydata + s->obsoletes;
	  while ((con = *conp++) != 0)
	    {
	      Id p2, pp2;
	      FOR_PROVIDES(p2, pp2, con)
		{
		  if (p2 == p || !pool_match_nevr(pool, pool->solvables + p2, con))
		    continue;
		  MAPEXP(conflicts, pool->nsolvables);
		  MAPSET(conflicts, p2);
		  if (xp->debug)
		    queue_push2(conflictsinfo, p2, -p);
		}
	    }
	}
      if (xp->debug)
	*cidone = out->count;
    }
}

static inline int
expander_checkconflicts(Expander *xp, Id p, Map *installed, Id *conflicts, int isobsoletes)
{
  Pool *pool = xp->pool;
  Id con, p2, pp2;

  if (xp->ignoreconflicts)
    return 0;
  while ((con = *conflicts++) != 0)
    {
      FOR_PROVIDES(p2, pp2, con)
	{
	  if (p == p2)
	    continue;
	  if (isobsoletes && !pool_match_nevr(pool, pool->solvables + p2, con))
	    continue;
	  if (MAPTST(installed, p2))
	    return p2;
	}
    }
  return 0;
}

static void
expander_updateconflictsinfo(Expander *xp, Queue *conflictsinfo, int *cidone, Queue *out)
{
  Pool *pool = xp->pool;
  int i;
  if (xp->ignoreconflicts)
    return;
  for (i = *cidone; i < out->count; i++)
    {
      Id p, p2, pp2;
      Id con, *conp;
      Solvable *s;
      p = out->elements[i];
      s = pool->solvables + p;
      /* keep in sync with expander_installed! */
      if (s->conflicts)
	{
	  conp = s->repo->idarraydata + s->conflicts;
	  while ((con = *conp++) != 0)
	    {
	      FOR_PROVIDES(p2, pp2, con)
		{
		  if (p2 == p)
		    continue;
		  queue_push2(conflictsinfo, p2, p);
		}
	    }
	}
      if (s->obsoletes)
	{
	  conp = s->repo->idarraydata + s->obsoletes;
	  while ((con = *conp++) != 0)
	    {
	      FOR_PROVIDES(p2, pp2, con)
		{
		  if (p2 == p || !pool_match_nevr(pool, pool->solvables + p2, con))
		    continue;
		  queue_push2(conflictsinfo, p2, -p);
		}
	    }
	}
    }
  *cidone = out->count;
}

static inline int
findconflictsinfo(Queue *conflictsinfo, Id p)
{
  int i;

  for (i = 0; i < conflictsinfo->count; i++)
    if (conflictsinfo->elements[i] == p)
      return conflictsinfo->elements[i + 1];
  return 0;
}

#define ERROR_NOPROVIDER		1
#define ERROR_CHOICE			2
#define ERROR_CONFLICTINGPROVIDER	3
#define ERROR_CONFLICTINGPROVIDERS	4
#define ERROR_PROVIDERINFO		5
#define ERROR_PROVIDERINFO2		6


int
expander_expand(Expander *xp, Queue *in, Queue *out, Queue *inconfl)
{
  Pool *pool = xp->pool;
  Queue todo, errors, cerrors, qq, posfoundq;
  Map installed;
  Map conflicts;
  Queue conflictsinfo;
  int cidone;
  Solvable *s;
  Id q, p, pp;
  int i, j, nerrors, doamb, ambcnt;
  Id id, who, whon, pn;
  Id conflprov, conflprovpc;

  map_init(&installed, pool->nsolvables);
  map_init(&conflicts, 0);
  queue_init(&conflictsinfo);
  queue_init(&todo);
  queue_init(&qq);
  queue_init(&errors);
  queue_init(&cerrors);
  queue_init(&posfoundq);

  queue_empty(out);
  cidone = 0;

  if (inconfl)
    {
      for (i = 0; i < inconfl->count; i += 2)
	{
	  Id con = inconfl->elements[i];
	  FOR_PROVIDES(p, pp, con)
	    {
	      if (inconfl->elements[i + 1] && !pool_match_nevr(pool, pool->solvables + p, con))
		continue;
	      MAPEXP(&conflicts, pool->nsolvables);
	      MAPSET(&conflicts, p);
	    }
	}
    }
  /* do direct expands */
  for (i = 0; i < in->count; i++)
    {
      id = in->elements[i];
      if (id == expander_directdepsend)
	{
	  for (i = i + 1; i < in->count; i++)
	    if (in->elements[i] != expander_directdepsend)
	      queue_push2(&todo, in->elements[i], 0);
	  break;
	}
      q = 0;
      FOR_PROVIDES(p, pp, id)
	{
	  s = pool->solvables + p;
	  if (!pool_match_nevr(pool, s, id))
	    continue;
	  if (q)
	    {
	      q = 0;
	      break;
	    }
	  q = p;
	}
      if (!q)
	{
	  /* unclear, resolve later */
	  queue_push2(&todo, id, 0);
	  continue;
	}
      if (MAPTST(&installed, q))
	continue;
      if (conflicts.size && MAPTST(&conflicts, q))
	{
	  queue_push(&errors, ERROR_CONFLICTINGPROVIDER);
	  queue_push2(&errors, id, 0);
	  if (cidone < out->count)
	    expander_updateconflictsinfo(xp, &conflictsinfo, &cidone, out);
	  queue_push(&errors, ERROR_PROVIDERINFO2);
	  queue_push2(&errors, q, findconflictsinfo(&conflictsinfo, q));
	  continue;
	}
      if (pool->solvables[q].conflicts && (pp = expander_checkconflicts(xp, q, &installed, pool->solvables[q].repo->idarraydata + pool->solvables[q].conflicts, 0)) != 0)
	{
	  queue_push(&errors, ERROR_CONFLICTINGPROVIDER);
	  queue_push2(&errors, id, 0);
	  queue_push(&errors, ERROR_PROVIDERINFO);
	  queue_push2(&errors, q, pp);
	  continue;
	}
      if (pool->solvables[q].obsoletes && (pp = expander_checkconflicts(xp, q, &installed, pool->solvables[q].repo->idarraydata + pool->solvables[q].obsoletes, 1)) != 0)
	{
	  queue_push(&errors, ERROR_CONFLICTINGPROVIDER);
	  queue_push2(&errors, id, 0);
	  queue_push(&errors, ERROR_PROVIDERINFO);
	  queue_push2(&errors, q, -pp);
	  continue;
	}
      if (xp->debug)
	expander_dbg(xp, "added %s because of %s (direct dep)\n", expander_solvid2name(xp, q), pool_dep2str(pool, id));
      expander_installed(xp, q, &installed, &conflicts, &conflictsinfo, &cidone, out, &todo); /* unique match! */
    }

  doamb = 0;
  ambcnt = todo.count;
  while (todo.count)
    {
      id = queue_shift(&todo);
      who = queue_shift(&todo);
      if (ambcnt == 0)
	{
	  if (doamb)
	    break;	/* amb pass had no progress, stop */
	  if (xp->debug)
	    expander_dbg(xp, "now doing undecided dependencies\n");
	  doamb = 1;	/* start amb pass */
	  ambcnt = todo.count;
	}
      else
	ambcnt -= 2;
// printf("todo %s %s ambcnt %d\n", pool_id2str(pool, pool->solvables[who].name), pool_dep2str(pool, id), ambcnt);
// fflush(stdout);
      whon = who ? pool->solvables[who].name : 0;
      queue_empty(&qq);
      conflprov = 0;
      conflprovpc = 0;
      FOR_PROVIDES(p, pp, id)
	{
	  Id pc;
	  if (MAPTST(&installed, p))
	    break;
	  if (who && !xp->ignoreignore)
	    {
	      Id pn = pool->solvables[p].name;
	      if (MAPTST(&xp->ignored, pn))
		break;
	      if (MAPTST(&xp->ignoredx, pn))
		{
		  Id xid = pool_str2id(pool, pool_tmpjoin(pool, pool_id2str(pool, whon), ":", pool_id2str(pool, pn)), 0);
		  if (xid && MAPTST(&xp->ignored, xid))
		    break;
		}
	    }
	  if (conflicts.size && MAPTST(&conflicts, p))
	    {
	      if (xp->debug)
		{
		  Id pc = findconflictsinfo(&conflictsinfo, p);
		  if (pc)
		    expander_dbg(xp, "ignoring provider %s of %s because installed %s %s it\n", pool_solvid2str(pool, p), pool_dep2str(pool, id), pool_solvid2str(pool, pc > 0 ? pc : -pc), pc > 0 ? "conflicts with" : "obsoletes");
		  else
		    expander_dbg(xp, "ignoring conflicted provider %s of %s\n", pool_solvid2str(pool, p), pool_dep2str(pool, id));
		}
	      conflprov = conflprov ? 1 : p;
	      conflprovpc = 0;
	      continue;
	    }
	  if (pool->solvables[p].conflicts && (pc = expander_checkconflicts(xp, p, &installed, pool->solvables[p].repo->idarraydata + pool->solvables[p].conflicts, 0)) != 0)
	    {
	      expander_dbg(xp, "ignoring provider %s of %s because it conflicts with installed %s\n", pool_solvid2str(pool, p), pool_dep2str(pool, id), pool_solvid2str(pool, pc));
	      conflprov = conflprov ? 1 : p;
	      conflprovpc = pc;
	      continue;
	    }
	  if (pool->solvables[p].obsoletes && (pc = expander_checkconflicts(xp, p, &installed, pool->solvables[p].repo->idarraydata + pool->solvables[p].obsoletes, 1)) != 0)
	    {
	      expander_dbg(xp, "ignoring provider %s of %s because it obsoletes installed %s\n", pool_solvid2str(pool, p), pool_dep2str(pool, id), pool_solvid2str(pool, pc));
	      conflprov = conflprov ? 1 : p;
	      conflprovpc = -pc;
	      continue;
	    }
	  queue_push(&qq, p);
	}
      if (p)
	continue;
      if (qq.count == 0)
	{
	  if (!conflprov)
	    {
	      queue_push(&errors, ERROR_NOPROVIDER);
	      queue_push2(&errors, id, who);
	      continue;
	    }
	  /* more work for conflicts */
	  if (conflprov != 1)
	    {
	      /* nice, just one provider */
	      queue_push(&errors, ERROR_CONFLICTINGPROVIDER);
	      queue_push2(&errors, id, who);
	      if (!conflprovpc)
		{
		  if (cidone < out->count)
		    expander_updateconflictsinfo(xp, &conflictsinfo, &cidone, out);
		  conflprovpc = findconflictsinfo(&conflictsinfo, conflprov);
		  queue_push(&errors, ERROR_PROVIDERINFO2);
		  queue_push2(&errors, conflprov, conflprovpc);
		}
	      else
		{
		  queue_push(&errors, ERROR_PROVIDERINFO);
		  queue_push2(&errors, conflprov, conflprovpc);
		}
	      continue;
	    }
	  /* even more work if all providers conflict */
	  queue_push(&errors, ERROR_CONFLICTINGPROVIDERS);
	  queue_push2(&errors, id, who);
	  if (cidone < out->count)
	    expander_updateconflictsinfo(xp, &conflictsinfo, &cidone, out);
	  FOR_PROVIDES(p, pp, id)
	    {
	      Id pc;
	      if (conflicts.size && MAPTST(&conflicts, p))
		{
		  pc = findconflictsinfo(&conflictsinfo, p);
		  queue_push(&errors, ERROR_PROVIDERINFO2);
		  queue_push2(&errors, p, pc);
		  continue;
		}
	      if (pool->solvables[p].conflicts && (pc = expander_checkconflicts(xp, p, &installed, pool->solvables[p].repo->idarraydata + pool->solvables[p].conflicts, 0)) != 0)
		{
		  queue_push(&errors, ERROR_PROVIDERINFO);
		  queue_push2(&errors, p, pc);
		  continue;
		}
	      if (pool->solvables[p].obsoletes && (pc = expander_checkconflicts(xp, p, &installed, pool->solvables[p].repo->idarraydata + pool->solvables[p].obsoletes, 1)) != 0)
		{
		  queue_push(&errors, ERROR_PROVIDERINFO);
		  queue_push2(&errors, p, -pc);
		  continue;
		}
	    }
	  continue;
	}
      if (qq.count > 1 && !doamb)
	{
	  /* try again later */
	  queue_push2(&todo, id, who);
	  if (xp->debug)
	    {
	      expander_dbg(xp, "undecided about %s:%s:", whon ? pool_id2str(pool, whon) : "(direct)", pool_dep2str(pool, id));
	      for (i = 0; i < qq.count; i++)
	        expander_dbg(xp, " %s", expander_solvid2name(xp, qq.elements[i]));
	      expander_dbg(xp, "\n");
	    }
	  continue;
	}

      /* prune neg prefers */
      if (qq.count > 1)
	{
	  for (i = j = 0; i < qq.count; i++)
	    {
	      p = qq.elements[i];
	      pn = pool->solvables[p].name;
	      if (MAPTST(&xp->preferneg, pn))
		continue;
	      if (who && MAPTST(&xp->prefernegx, pn))
		{
		  Id xid = pool_str2id(pool, pool_tmpjoin(pool, pool_id2str(pool, whon), ":", pool_id2str(pool, pn)), 0);
		  if (xid && MAPTST(&xp->preferneg, xid))
		    continue;
		}
	      qq.elements[j++] = p;
	    }
	  if (j)
	    queue_truncate(&qq, j);
	}

      /* prune pos prefers */
      if (qq.count > 1)
	{
	  queue_empty(&posfoundq);
	  for (i = j = 0; i < qq.count; i++)
	    {
	      p = qq.elements[i];
	      pn = pool->solvables[p].name;
	      if (MAPTST(&xp->preferpos, pn))
		{
		  queue_push2(&posfoundq, pn, p);
		  qq.elements[j++] = p;
		  continue;
		}
	      if (who && MAPTST(&xp->preferposx, pn))
		{
		  Id xid = pool_str2id(pool, pool_tmpjoin(pool, pool_id2str(pool, whon), ":", pool_id2str(pool, pn)), 0);
		  if (xid && MAPTST(&xp->preferpos, xid))
		    {
		      queue_push2(&posfoundq, xid, p);
		      qq.elements[j++] = p;
		      continue;
		    }
		}
	    }
	  if (posfoundq.count == 2)
	    {
	      queue_empty(&qq);
	      queue_push(&qq, posfoundq.elements[1]);
	    }
	  else if (posfoundq.count)
	    {
	      /* found a pos prefer, now find first hit */
	      /* (prefers are ordered) */
	      for (i = 0; i < xp->preferposq.count; i++)
		{
		  Id xid = xp->preferposq.elements[i];
		  for (j = 0; j < posfoundq.count; j += 2)
		    if (posfoundq.elements[j] == xid)
		      break;
		  if (j < posfoundq.count)
		    {
		      queue_empty(&qq);
		      queue_push(&qq, posfoundq.elements[j + 1]);
		      break;
		    }
		}
	    }
	}

      /* prune OR deps */
      if (qq.count > 1 && ISRELDEP(id) && GETRELDEP(pool, id)->flags == REL_OR)
	{
	  Id rid = id;
	  for (;;)
	    {
	      Reldep *rd = 0;
	      if (ISRELDEP(rid))
		{
		  rd = GETRELDEP(pool, rid);
		  if (rd->flags != REL_OR)
		    rd = 0;
		}
	      if (rd)
		rid = rd->name;
	      queue_empty(&qq);
	      FOR_PROVIDES(p, pp, rid)
		queue_push(&qq, p);
	      if (qq.count)
		break;
	      if (rd)
	        rid = rd->evr;
	      else
		break;
	    }
	}

      /* prioritize suggests and recommends */
      if (qq.count > 1 && (pool->solvables[who].recommends || pool->solvables[who].suggests))
        {
          Solvable *t = pool->solvables + who;
          Id *rec, *sug;
          Queue qr, qs;
          Id q, p, reccomended, suggested;
          int i;

          queue_init(&qr);
          queue_init(&qs);

          for (i = 0; i < qq.count; i++)
            {
              rec = t->repo->idarraydata + t->recommends;
              sug = t->repo->idarraydata + t->suggests;
              q = qq.elements[i];

              while ((p = *rec++) != 0)
                {
                  if (!strncmp(pool_id2str(pool, p), pool_id2str(pool, pool->solvables[q].name), 32))
                    {
                      queue_push(&qr, q);
                    }
                }
              while ((p = *sug++) != 0)
                {
                  if (!strncmp(pool_id2str(pool, p), pool_id2str(pool, pool->solvables[q].name), 32))
                    {
                      queue_push(&qs, q);
                    }
                }
            }

          /* Recommends has higher priority than suggests */
          if (qr.count > 0)
            {
              queue_empty(&qq);
              for (i = 0; i < qr.count; i++)
                {
                  queue_push(&qq, qr.elements[i]);
                }
          }
          else if (qs.count > 0)
          {
              queue_empty(&qq);
              for (i = 0; i < qs.count; i++)
                {
                  queue_push(&qq, qs.elements[i]);
                }
          }
          else {
          }
          /* if qs == qr == 0, do not touch qq: nothing recommended or suggested */
        }

      if (qq.count > 1)
	{
	  queue_push(&cerrors, ERROR_CHOICE);
	  queue_push2(&cerrors, id, who);
	  for (i = 0; i < qq.count; i++)
	    queue_push(&cerrors, qq.elements[i]);
	  queue_push(&cerrors, 0);
	  /* try again later */
	  queue_push2(&todo, id, who);
	  continue;
	}
      if (xp->debug)
	expander_dbg(xp, "added %s because of %s:%s\n", expander_solvid2name(xp, qq.elements[0]), whon ? pool_id2str(pool, whon) : "(direct)", pool_dep2str(pool, id));
      expander_installed(xp, qq.elements[0], &installed, &conflicts, &conflictsinfo, &cidone, out, &todo);
      doamb = 0;
      ambcnt = todo.count;
      queue_empty(&cerrors);
    }
  map_free(&installed);
  map_free(&conflicts);
  queue_free(&conflictsinfo);
  nerrors = 0;
  if (errors.count || cerrors.count)
    {
      queue_empty(out);
      for (i = 0; i < errors.count; i += 3)
	{
	  queue_push(out, errors.elements[i]);
	  queue_push(out, errors.elements[i + 1]);
	  queue_push(out, errors.elements[i + 2]);
	  nerrors++;
	}
      for (i = 0; i < cerrors.count; )
	{
	  queue_push(out, cerrors.elements[i]);
	  queue_push(out, cerrors.elements[i + 1]);
	  queue_push(out, cerrors.elements[i + 2]);
	  i += 3;
	  while (cerrors.elements[i])
	    {
	      queue_push(out, cerrors.elements[i]);
	      i++;
	    }
	  queue_push(out, 0);
	  i++;
	  nerrors++;
	}
    }
  else
    {
      if (todo.count)
	{
	  fprintf(stderr, "Internal expansion error!\n");
	  queue_empty(out);
	  queue_push(out, ERROR_NOPROVIDER);
	  queue_push(out, 0);
	  queue_push(out, 0);
	}
    }
  queue_free(&todo);
  queue_free(&qq);
  queue_free(&errors);
  queue_free(&cerrors);
  queue_free(&posfoundq);
  return nerrors;
}

static void
set_disttype(Pool *pool, int disttype)
{
  pool_setdisttype(pool, disttype);
#ifdef POOL_FLAG_HAVEDISTEPOCH
  /* make newer mandriva work, hopefully there are no ill effects... */
  pool_set_flag(pool, POOL_FLAG_HAVEDISTEPOCH, disttype == DISTTYPE_RPM ? 1 : 0);
#endif
}

static void
set_disttype_from_location(Pool *pool, Solvable *so)
{
  unsigned int medianr;
  const char *s = solvable_get_location(so, &medianr);
  int disttype = -1;
  int sl;
  if (!s)
    return;
  sl = strlen(s);
  if (disttype < 0 && sl >= 4 && !strcmp(s + sl - 4, ".rpm"))
    disttype = DISTTYPE_RPM;
#ifdef DISTTYPE_DEB
  if (disttype < 0 && sl >= 4 && !strcmp(s + sl - 4, ".deb"))
    disttype = DISTTYPE_DEB;
#endif
#ifdef DISTTYPE_ARCH
  if (disttype < 0 && sl >= 11 && (!strcmp(s + sl - 11, ".pkg.tar.gz") || !strcmp(s + sl - 11, ".pkg.tar.xz")))
    disttype = DISTTYPE_ARCH;
#endif
  if (disttype >= 0 && pool->disttype != disttype)
    set_disttype(pool, disttype);
}

void
create_considered(Pool *pool, Repo *repoonly, Map *considered)
{
  Id p, pb,*best;
  Solvable *s, *sb;
  int ridx;
  Repo *repo;
  int olddisttype = -1;
  int dodrepo;

  map_init(considered, pool->nsolvables);
  best = solv_calloc(sizeof(Id), pool->ss.nstrings);
  
  FOR_REPOS(ridx, repo)
    {
      if (repoonly && repo != repoonly)
	continue;
      dodrepo = repo_lookup_str(repo, SOLVID_META, buildservice_dodurl) != 0;
      FOR_REPO_SOLVABLES(repo, p, s)
	{
	  if (s->arch == ARCH_SRC || s->arch == ARCH_NOSRC)
	    continue;
	  pb = best[s->name];
	  if (pb)
	    {
	      sb = pool->solvables + pb;
	      if (s->repo != sb->repo)
		continue;	/* first repo wins */
	      if (s->arch != sb->arch)
		{
		  int r;
		  if (s->arch == ARCH_NOARCH || s->arch == ARCH_ALL || s->arch == ARCH_ANY)
		    continue;
		  if (sb->arch != ARCH_NOARCH && sb->arch != ARCH_ALL && sb->arch != ARCH_ANY)
		    {
		      /* the strcmp is kind of silly, but works for most archs */
		      r = strcmp(pool_id2str(pool, sb->arch), pool_id2str(pool, s->arch));
		      if (r >= 0)
			continue;
		    }
		}
	      else if (s->evr != sb->evr)
		{
		  /* same repo, check versions */
		  int r;
		  if (olddisttype < 0)
		    {
		      olddisttype = pool->disttype;
		      set_disttype_from_location(pool, s);
		    }
		  r = pool_evrcmp(pool, sb->evr, s->evr, EVRCMP_COMPARE);
		  if (r > 0)
		    continue;
		  else if (r == 0)
		    {
		      r = strcmp(pool_id2str(pool, sb->evr), pool_id2str(pool, s->evr));
		      if (r >= 0)
			continue;
		    }
		}
	    }
	   if (dodrepo)
	    {
	      /* we only consider dod packages */
	      const char *bsid = solvable_lookup_str(s, buildservice_id);
	      if (!bsid || strcmp(bsid, "dod") != 0)
		continue;
	    }
	  if (pb)
	    MAPCLR(considered, pb);
	  best[s->name] = p;
	  MAPSET(considered, p);
	}
      /* dodrepos have a second pass: replace dod entries with downloaded ones */
      if (dodrepo)
	{
	  const char *bsid;
	  FOR_REPO_SOLVABLES(repo, p, s)
	    {
	      if (s->arch == ARCH_SRC || s->arch == ARCH_NOSRC)
		continue;
	      pb = best[s->name];
	      if (!pb || pb == p)
		continue;
	      sb = pool->solvables + pb;
	      if (sb->repo != s->repo || sb->name != s->name || sb->arch != s->arch || sb->evr != s->evr)
		continue;
	      bsid = solvable_lookup_str(s, buildservice_id);
	      if (bsid && strcmp(bsid, "dod") == 0)
		continue;	/* not downloaded */
	      MAPCLR(considered, pb);
	      best[s->name] = p;
	      MAPSET(considered, p);
	    }
	}
    }
  solv_free(best);
  if (olddisttype >= 0 && pool->disttype != olddisttype)
    set_disttype(pool, olddisttype);
}

struct metaline {
  char *l;
  int lastoff;
  int nslash;
  int killed;
};

static int metacmp(const void *ap, const void *bp)
{
  const struct metaline *a, *b;
  int r;

  a = ap;
  b = bp;
  r = a->nslash - b->nslash;
  if (r)
    return r;
  r = strcmp(a->l + 34, b->l + 34);
  if (r)
    return r;
  r = strcmp(a->l, b->l);
  if (r)
    return r;
  return a - b;
}

#ifndef REPO_NO_LOCATION
# define REPO_NO_LOCATION 0
#endif

Id
repodata_addbin(Repodata *data, char *prefix, char *s, int sl, char *sid)
{
  Id p = 0;
  char *path;
#if REPO_NO_LOCATION == 0
  char *sp;
#endif

  path = solv_dupjoin(prefix, "/", s);
  if (sl >= 4 && !strcmp(s + sl - 4, ".rpm"))
    p = repo_add_rpm(data->repo, (const char *)path, REPO_REUSE_REPODATA|REPO_NO_INTERNALIZE|REPO_NO_LOCATION|RPM_ADD_WITH_PKGID|RPM_ADD_NO_FILELIST|RPM_ADD_NO_RPMLIBREQS);
  else if (sl >= 4 && !strcmp(s + sl - 4, ".deb"))
    p = repo_add_deb(data->repo, (const char *)path, REPO_REUSE_REPODATA|REPO_NO_INTERNALIZE|REPO_NO_LOCATION|DEBS_ADD_WITH_PKGID);
#ifdef ARCH_ADD_WITH_PKGID
  else if (sl >= 11 && (!strcmp(s + sl - 11, ".pkg.tar.gz") || !strcmp(s + sl - 11, ".pkg.tar.xz")))
    p = repo_add_arch_pkg(data->repo, (const char *)path, REPO_REUSE_REPODATA|REPO_NO_INTERNALIZE|REPO_NO_LOCATION|ARCH_ADD_WITH_PKGID);
#endif
  solv_free(path);
  if (!p)
    return 0;
#if REPO_NO_LOCATION != 0
  repodata_set_location(data, p, 0, 0, s);
#else
  if ((sp = strrchr(s, '/')) != 0)
    {
      *sp = 0;
      repodata_set_str(data, p, SOLVABLE_MEDIADIR, s);
      *sp = '/';
    }
  else
    repodata_delete_uninternalized(data, p, SOLVABLE_MEDIADIR);
#endif
  repodata_set_str(data, p, buildservice_id, sid);
  return p;
}

static int
subpack_sort_cmp(const void *ap, const void *bp, void *dp)
{
  Pool *pool = (Pool *)dp;
  const Id *a = ap;
  const Id *b = bp;
  int r = a[1] - b[1];
  if (r)
    return r;
  r = strcmp(pool_id2str(pool, a[0]), pool_id2str(pool, b[0]));
  return r ? r : a[0] - b[0];
}

/* This is an OpenSSL-compatible implementation of the RSA Data Security,
 * Inc. MD5 Message-Digest Algorithm.
 *
 * Written by Solar Designer <solar@openwall.com> in 2001, and placed in
 * the public domain. */

#define F(x, y, z)                      ((z) ^ ((x) & ((y) ^ (z))))
#define G(x, y, z)                      ((y) ^ ((z) & ((x) ^ (y))))
#define H(x, y, z)                      ((x) ^ (y) ^ (z))
#define I(x, y, z)                      ((y) ^ ((x) | ~(z)))

#define STEP(f, a, b, c, d, x, t, s) \
        (a) += f((b), (c), (d)) + (x) + (t); \
        (a) = (((a) << (s)) | (((a) & 0xffffffff) >> (32 - (s)))); \
        (a) += (b);

#if defined(__i386__) || defined(__vax__)
#define SET(n) \
        (*(MD5_u32plus *)&ptr[(n) * 4])
#define GET(n) \
        SET(n)
#else
#define SET(n) \
        (ctx->block[(n)] = \
        (MD5_u32plus)ptr[(n) * 4] | \
        ((MD5_u32plus)ptr[(n) * 4 + 1] << 8) | \
        ((MD5_u32plus)ptr[(n) * 4 + 2] << 16) | \
        ((MD5_u32plus)ptr[(n) * 4 + 3] << 24))
#define GET(n) \
        (ctx->block[(n)])
#endif

typedef unsigned long MD5_u32plus;

typedef struct {
        MD5_u32plus lo, hi;
        MD5_u32plus a, b, c, d;
        unsigned char buffer[64];
        MD5_u32plus block[16];
} MD5_CTX;

/*
 * This processes one or more 64-byte data blocks, but does NOT update
 * the bit counters.  There're no alignment requirements.
 */
static void *md5_body(MD5_CTX *ctx, void *data, unsigned long size)
{
        unsigned char *ptr;
        MD5_u32plus a, b, c, d;
        MD5_u32plus saved_a, saved_b, saved_c, saved_d;

        ptr = data;

        a = ctx->a;
        b = ctx->b;
        c = ctx->c;
        d = ctx->d;

        do {
                saved_a = a;
                saved_b = b;
                saved_c = c;
                saved_d = d;

/* Round 1 */
                STEP(F, a, b, c, d, SET(0), 0xd76aa478, 7)
                STEP(F, d, a, b, c, SET(1), 0xe8c7b756, 12)
                STEP(F, c, d, a, b, SET(2), 0x242070db, 17)
                STEP(F, b, c, d, a, SET(3), 0xc1bdceee, 22)
                STEP(F, a, b, c, d, SET(4), 0xf57c0faf, 7)
                STEP(F, d, a, b, c, SET(5), 0x4787c62a, 12)
                STEP(F, c, d, a, b, SET(6), 0xa8304613, 17)
                STEP(F, b, c, d, a, SET(7), 0xfd469501, 22)
                STEP(F, a, b, c, d, SET(8), 0x698098d8, 7)
                STEP(F, d, a, b, c, SET(9), 0x8b44f7af, 12)
                STEP(F, c, d, a, b, SET(10), 0xffff5bb1, 17)
                STEP(F, b, c, d, a, SET(11), 0x895cd7be, 22)
                STEP(F, a, b, c, d, SET(12), 0x6b901122, 7)
                STEP(F, d, a, b, c, SET(13), 0xfd987193, 12)
                STEP(F, c, d, a, b, SET(14), 0xa679438e, 17)
                STEP(F, b, c, d, a, SET(15), 0x49b40821, 22)

/* Round 2 */
                STEP(G, a, b, c, d, GET(1), 0xf61e2562, 5)
                STEP(G, d, a, b, c, GET(6), 0xc040b340, 9)
                STEP(G, c, d, a, b, GET(11), 0x265e5a51, 14)
                STEP(G, b, c, d, a, GET(0), 0xe9b6c7aa, 20)
                STEP(G, a, b, c, d, GET(5), 0xd62f105d, 5)
                STEP(G, d, a, b, c, GET(10), 0x02441453, 9)
                STEP(G, c, d, a, b, GET(15), 0xd8a1e681, 14)
                STEP(G, b, c, d, a, GET(4), 0xe7d3fbc8, 20)
                STEP(G, a, b, c, d, GET(9), 0x21e1cde6, 5)
                STEP(G, d, a, b, c, GET(14), 0xc33707d6, 9)
                STEP(G, c, d, a, b, GET(3), 0xf4d50d87, 14)
                STEP(G, b, c, d, a, GET(8), 0x455a14ed, 20)
                STEP(G, a, b, c, d, GET(13), 0xa9e3e905, 5)
                STEP(G, d, a, b, c, GET(2), 0xfcefa3f8, 9)
                STEP(G, c, d, a, b, GET(7), 0x676f02d9, 14)
                STEP(G, b, c, d, a, GET(12), 0x8d2a4c8a, 20)

/* Round 3 */
                STEP(H, a, b, c, d, GET(5), 0xfffa3942, 4)
                STEP(H, d, a, b, c, GET(8), 0x8771f681, 11)
                STEP(H, c, d, a, b, GET(11), 0x6d9d6122, 16)
                STEP(H, b, c, d, a, GET(14), 0xfde5380c, 23)
                STEP(H, a, b, c, d, GET(1), 0xa4beea44, 4)
                STEP(H, d, a, b, c, GET(4), 0x4bdecfa9, 11)
                STEP(H, c, d, a, b, GET(7), 0xf6bb4b60, 16)
                STEP(H, b, c, d, a, GET(10), 0xbebfbc70, 23)
                STEP(H, a, b, c, d, GET(13), 0x289b7ec6, 4)
                STEP(H, d, a, b, c, GET(0), 0xeaa127fa, 11)
                STEP(H, c, d, a, b, GET(3), 0xd4ef3085, 16)
                STEP(H, b, c, d, a, GET(6), 0x04881d05, 23)
                STEP(H, a, b, c, d, GET(9), 0xd9d4d039, 4)
                STEP(H, d, a, b, c, GET(12), 0xe6db99e5, 11)
                STEP(H, c, d, a, b, GET(15), 0x1fa27cf8, 16)
                STEP(H, b, c, d, a, GET(2), 0xc4ac5665, 23)

/* Round 4 */
                STEP(I, a, b, c, d, GET(0), 0xf4292244, 6)
                STEP(I, d, a, b, c, GET(7), 0x432aff97, 10)
                STEP(I, c, d, a, b, GET(14), 0xab9423a7, 15)
                STEP(I, b, c, d, a, GET(5), 0xfc93a039, 21)
                STEP(I, a, b, c, d, GET(12), 0x655b59c3, 6)
                STEP(I, d, a, b, c, GET(3), 0x8f0ccc92, 10)
                STEP(I, c, d, a, b, GET(10), 0xffeff47d, 15)
                STEP(I, b, c, d, a, GET(1), 0x85845dd1, 21)
                STEP(I, a, b, c, d, GET(8), 0x6fa87e4f, 6)
                STEP(I, d, a, b, c, GET(15), 0xfe2ce6e0, 10)
                STEP(I, c, d, a, b, GET(6), 0xa3014314, 15)
                STEP(I, b, c, d, a, GET(13), 0x4e0811a1, 21)
                STEP(I, a, b, c, d, GET(4), 0xf7537e82, 6)
                STEP(I, d, a, b, c, GET(11), 0xbd3af235, 10)
                STEP(I, c, d, a, b, GET(2), 0x2ad7d2bb, 15)
                STEP(I, b, c, d, a, GET(9), 0xeb86d391, 21)

                a += saved_a;
                b += saved_b;
                c += saved_c;
                d += saved_d;

                ptr += 64;
        } while (size -= 64);

        ctx->a = a;
        ctx->b = b;
        ctx->c = c;
        ctx->d = d;

        return ptr;
}

static void md5_init(MD5_CTX *ctx)
{
        ctx->a = 0x67452301;
        ctx->b = 0xefcdab89;
        ctx->c = 0x98badcfe;
        ctx->d = 0x10325476;
        ctx->lo = 0;
        ctx->hi = 0;
}

static void md5_update(MD5_CTX *ctx, void *data, unsigned long size)
{
        MD5_u32plus saved_lo;
        unsigned long used, free;

        saved_lo = ctx->lo;
        if ((ctx->lo = (saved_lo + size) & 0x1fffffff) < saved_lo)
                ctx->hi++;
        ctx->hi += size >> 29;

        used = saved_lo & 0x3f;

        if (used) {
                free = 64 - used;

                if (size < free) {
                        memcpy(&ctx->buffer[used], data, size);
                        return;
                }

                memcpy(&ctx->buffer[used], data, free);
                data = (unsigned char *)data + free;
                size -= free;
                md5_body(ctx, ctx->buffer, 64);
        }

        if (size >= 64) {
                data = md5_body(ctx, data, size & ~(unsigned long)0x3f);
                size &= 0x3f;
        }

        memcpy(ctx->buffer, data, size);
}

static void md5_final(MD5_CTX *ctx, unsigned char *result)
{
        unsigned long used, free;
        used = ctx->lo & 0x3f;
        ctx->buffer[used++] = 0x80;
        free = 64 - used;
        if (free < 8) {
                memset(&ctx->buffer[used], 0, free);
                md5_body(ctx, ctx->buffer, 64);
                used = 0;
                free = 64;
        }
        memset(&ctx->buffer[used], 0, free - 8);
        ctx->lo <<= 3;
        ctx->buffer[56] = ctx->lo;
        ctx->buffer[57] = ctx->lo >> 8;
        ctx->buffer[58] = ctx->lo >> 16;
        ctx->buffer[59] = ctx->lo >> 24;
        ctx->buffer[60] = ctx->hi;
        ctx->buffer[61] = ctx->hi >> 8;
        ctx->buffer[62] = ctx->hi >> 16;
        ctx->buffer[63] = ctx->hi >> 24;
        md5_body(ctx, ctx->buffer, 64);
        result[0] = ctx->a;
        result[1] = ctx->a >> 8;
        result[2] = ctx->a >> 16;
        result[3] = ctx->a >> 24;
        result[4] = ctx->b;
        result[5] = ctx->b >> 8;
        result[6] = ctx->b >> 16;
        result[7] = ctx->b >> 24;
        result[8] = ctx->c;
        result[9] = ctx->c >> 8;
        result[10] = ctx->c >> 16;
        result[11] = ctx->c >> 24;
        result[12] = ctx->d;
        result[13] = ctx->d >> 8;
        result[14] = ctx->d >> 16;
        result[15] = ctx->d >> 24;
        memset(ctx, 0, sizeof(*ctx));
}

static unsigned int buz_noise[256] =
{
  0x9be502a4U, 0xba7180eaU, 0x324e474fU, 0x0aab8451U, 0x0ced3810U,
  0x2158a968U, 0x6bbd3771U, 0x75a02529U, 0x41f05c14U, 0xc2264b87U,
  0x1f67b359U, 0xcd2d031dU, 0x49dc0c04U, 0xa04ae45cU, 0x6ade28a7U,
  0x2d0254ffU, 0xdec60c7cU, 0xdef5c084U, 0x0f77ffc8U, 0x112021f6U,
  0x5f6d581eU, 0xe35ea3dfU, 0x3216bfb4U, 0xd5a3083dU, 0x7e63e9cdU,
  0xaa9208f6U, 0xda3f3978U, 0xfe0e2547U, 0x09dfb020U, 0xd97472c5U,
  0xbbce2edeU, 0x121aebd2U, 0x0e9fdbebU, 0x7b6f5d9cU, 0x84938e43U,
  0x30694f2dU, 0x86b7a7f8U, 0xefaf5876U, 0x263812e6U, 0xb6e48ddfU,
  0xce8ed980U, 0x4df591e1U, 0x75257b35U, 0x2f88dcffU, 0xa461fe44U,
  0xca613b4dU, 0xd9803f73U, 0xea056205U, 0xccca7a89U, 0x0f2dbb07U,
  0xc53e359eU, 0xe80d0137U, 0x2b2d2a5dU, 0xcfc1391aU, 0x2bb3b6c5U,
  0xb66aea3cU, 0x00ea419eU, 0xce5ada84U, 0xae1d6712U, 0x12f576baU,
  0x117fcbc4U, 0xa9d4c775U, 0x25b3d616U, 0xefda65a8U, 0xaff3ef5bU,
  0x00627e68U, 0x668d1e99U, 0x088d0eefU, 0xf8fac24dU, 0xe77457c7U,
  0x68d3beb4U, 0x921d2acbU, 0x9410eac9U, 0xd7f24399U, 0xcbdec497U,
  0x98c99ae1U, 0x65802b2cU, 0x81e1c3c4U, 0xa130bb09U, 0x17a87badU,
  0xa70367d6U, 0x148658d4U, 0x02f33377U, 0x8620d8b6U, 0xbdac25bdU,
  0xb0a6de51U, 0xd64c4571U, 0xa4185ba0U, 0xa342d70fU, 0x3f1dc4c1U,
  0x042dc3ceU, 0x0de89f43U, 0xa69b1867U, 0x3c064e11U, 0xad1e2c3eU,
  0x9660e8cdU, 0xd36b09caU, 0x4888f228U, 0x61a9ac3cU, 0xd9561118U,
  0x3532797eU, 0x71a35c22U, 0xecc1376cU, 0xab31e656U, 0x88bd0d35U,
  0x423b20ddU, 0x38e4651cU, 0x3c6397a4U, 0x4a7b12d9U, 0x08b1cf33U,
  0xd0604137U, 0xb035fdb8U, 0x4916da23U, 0xa9349493U, 0xd83daa9bU,
  0x145f7d95U, 0x868531d6U, 0xacb18f17U, 0x9cd33b6fU, 0x193e42b9U,
  0x26dfdc42U, 0x5069d8faU, 0x5bee24eeU, 0x5475d4c6U, 0x315b2c0cU,
  0xf764ef45U, 0x01b6f4ebU, 0x60ba3225U, 0x8a16777cU, 0x4c05cd28U,
  0x53e8c1d2U, 0xc8a76ce5U, 0x8045c1e6U, 0x61328752U, 0x2ebad322U,
  0x3444f3e2U, 0x91b8af11U, 0xb0cee675U, 0x55dbff5aU, 0xf7061ee0U,
  0x27d7d639U, 0xa4aef8c9U, 0x42ff0e4fU, 0x62755468U, 0x1c6ca3f3U,
  0xe4f522d1U, 0x2765fcb3U, 0xe20c8a95U, 0x3a69aea7U, 0x56ab2c4fU,
  0x8551e688U, 0xe0bc14c2U, 0x278676bfU, 0x893b6102U, 0xb4f0ab3bU,
  0xb55ddda9U, 0xa04c521fU, 0xc980088eU, 0x912aeac1U, 0x08519badU,
  0x991302d3U, 0x5b91a25bU, 0x696d9854U, 0x9ad8b4bfU, 0x41cb7e21U,
  0xa65d1e03U, 0x85791d29U, 0x89478aa7U, 0x4581e337U, 0x59bae0b1U,
  0xe0fc9df3U, 0x45d9002cU, 0x7837464fU, 0xda22de3aU, 0x1dc544bdU,
  0x601d8badU, 0x668b0abcU, 0x7a5ebfb1U, 0x3ac0b624U, 0x5ee16d7dU,
  0x9bfac387U, 0xbe8ef20cU, 0x8d2ae384U, 0x819dc7d5U, 0x7c4951e7U,
  0xe60da716U, 0x0c5b0073U, 0xb43b3d97U, 0xce9974edU, 0x0f691da9U,
  0x4b616d60U, 0x8fa9e819U, 0x3f390333U, 0x6f62fad6U, 0x5a32b67cU,
  0x3be6f1c3U, 0x05851103U, 0xff28828dU, 0xaa43a56aU, 0x075d7dd5U,
  0x248c4b7eU, 0x52fde3ebU, 0xf72e2edaU, 0x5da6f75fU, 0x2f5148d9U,
  0xcae2aeaeU, 0xfda6f3e5U, 0xff60d8ffU, 0x2adc02d2U, 0x1dbdbd4cU,
  0xd410ad7cU, 0x8c284aaeU, 0x392ef8e0U, 0x37d48b3aU, 0x6792fe9dU,
  0xad32ddfaU, 0x1545f24eU, 0x3a260f73U, 0xb724ca36U, 0xc510d751U,
  0x4f8df992U, 0x000b8b37U, 0x292e9b3dU, 0xa32f250fU, 0x8263d144U,
  0xfcae0516U, 0x1eae2183U, 0xd4af2027U, 0xc64afae3U, 0xe7b34fe4U,
  0xdf864aeaU, 0x80cc71c5U, 0x0e814df3U, 0x66cc5f41U, 0x853a497aU,
  0xa2886213U, 0x5e34a2eaU, 0x0f53ba47U, 0x718c484aU, 0xfa0f0b12U,
  0x33cc59ffU, 0x72b48e07U, 0x8b6f57bcU, 0x29cf886dU, 0x1950955bU,
  0xcd52910cU, 0x4cecef65U, 0x05c2cbfeU, 0x49df4f6aU, 0x1f4c3f34U,
  0xfadc1a09U, 0xf2d65a24U, 0x117f5594U, 0xde3a84e6U, 0x48db3024U,
  0xd10ca9b5U
};


/* 
 * our delta search blocksize
 *
 * smaller gives more hits, but increases the hash size
 *
 * must be a multiple of 256
 * must be in range [256,32767]
 */
#define DELTA_BSIZE 1024

/* min store block len, smaller blocks are encoded as direct data */
#define MIN_BSIZE 32

/* min meta block len, must be >= 10 */
#define MIN_BSIZE_META 32

/* max meta block len, must be <= DELTA_BSIZE */
#define MAX_BSIZE_META DELTA_BSIZE

/* number of slots per data area */
#define SLOTS_PER_AREA	4095


/* buzhash by Robert C. Uzgalis */
/* General hash functions. Technical Report TR-92-01, The University
   of Hong Kong, 1993 */

static unsigned int buzhash(unsigned char *buf)
{
  unsigned int x = 0x83d31df4U;
  int i;
  for (i = DELTA_BSIZE ; i != 0; i--)
    x = (x << 1) ^ (x & (1 << 31) ? 1 : 0) ^ buz_noise[*buf++];
  return x;
}

static void md5block(unsigned char *buf, int len, unsigned char *out)
{
  MD5_CTX ctx;
  md5_init(&ctx);
  md5_update(&ctx, buf, (unsigned long)len);
  md5_final(&ctx, out);
}

#define HASHCHAIN_START 7
#define HASHCHAIN_NEXT(h, hh, mask) (((h) + (hh)++) & (mask))


struct deltastore {
  int fd;				/* file descriptor */
  int rdonly;				/* store is read only */

  unsigned long long end;		/* store file size */

  unsigned long long *offsets;		/* the data areas we know about */
  int noffsets;

  unsigned char *hash;			/* our hash */
  unsigned int hm;			/* size of hash */
  unsigned int hf;			/* hash fill */
  unsigned int hd;			/* entries not in hash */

  int freecnt;				/* free slots in last slot area */
  int usedcnt;				/* used slots in last slot area */
  unsigned long long slotsoffset;	/* offset of last slot area */
};

struct deltaout {
  FILE *fp;
  struct deltastore *store;

  /* for block coalescence */
  unsigned long long oldoffset;
  unsigned long long oldsize;

  /* for offset encoding */
  unsigned long long lastoffset;

  /* for meta block creation */
  int outbuf_do_meta;				/* create meta blocks */
  unsigned char outbuf[MAX_BSIZE_META + 16];	/* 16 extra bytes for one encoded block */
  int outbuf_len;
  /* offset patching */
  unsigned long long outbuf_startoffset;
  int outbuf_startoffset_set;
  int outbuf_set_len1;
  int outbuf_set_len2;
  unsigned long long outbuf_set_offset;		/* offset we need to patch in, already encoded */
};

static inline unsigned long long getu48(unsigned char *d)
{
  unsigned long long x = d[0] << 8 | d[1];
  return (x << 32) | (d[2] << 24 | d[3] << 16 | d[4] << 8 | d[5]);
}

static inline void putu48(unsigned char *d, unsigned long long x)
{
  d[0] = x >> 40;
  d[1] = x >> 32;
  d[2] = x >> 24;
  d[3] = x >> 16;
  d[4] = x >> 8;
  d[5] = x;
}

static inline unsigned int getu32(unsigned char *d)
{
  return d[0] << 24 | d[1] << 16 | d[2] << 8 | d[3];
}

static inline void putu32(unsigned char *d, unsigned int x)
{
  d[0] = x >> 24;
  d[1] = x >> 16;
  d[2] = x >> 8;
  d[3] = x;
}

/**
 **  store handling
 **/

static int
finddataarea(struct deltastore *store, unsigned long long offset)
{
  int i;
  for (i = 0; i < store->noffsets; i += 2)
    if (offset >= store->offsets[i] && offset < store->offsets[i + 1])
      return i;
  return -1;
}

static void
adddataarea(struct deltastore *store, unsigned long long start, unsigned long long end)
{
  unsigned long long *newoffsets;
  if (store->noffsets && store->offsets[store->noffsets - 1] == start)
    {
      store->offsets[store->noffsets - 1] = end;
      return;
    }
  if (store->offsets)
    newoffsets = realloc(store->offsets, (store->noffsets + 2) * sizeof(unsigned long long));
  else
    newoffsets = malloc((store->noffsets + 2) * sizeof(unsigned long long));
  if (!newoffsets)
    return;
  newoffsets[store->noffsets++] = start;
  newoffsets[store->noffsets++] = end;
  store->offsets = newoffsets;
}

static int
addslotarea(struct deltastore *store, int cnt)
{
  unsigned char *slots;
  if (!cnt || cnt > 65535)
    return 0;
  if (store->rdonly)
    return 0;
  if ((store->end & 4095) != 0)		/* pad to multiple of 4096 */
    {
      char pad[4096];
      int l = 4096 - (store->end & 4095);
      memset(pad, 0, l);
      if (pwrite(store->fd, pad, l, store->end) != l)
	{
	  perror("pwrite pad next slotsarea");
	  return 0;
	}
      store->end += l;
    }
  if (store->end + (cnt + 1) * 16 >= (1LL << 48))
    return 0;				/* store too big! */
  slots = calloc(cnt + 1, 16);
  if (!slots)
    return 0;
  memcpy(slots, "OBSDELT", 8);
  slots[8] = cnt >> 8;
  slots[9] = cnt;
  /* write pointer to next slot area */
  if (store->end)
    {
      putu48(slots + 10, store->end);
      if (pwrite(store->fd, slots, 16, store->slotsoffset) != 16)
	{
	  perror("pwrite update next slotsarea");
	  free(slots);
	  return 0;
	}
      memset(slots + 10, 0, 6);
    }
  if (pwrite(store->fd, slots, (cnt + 1) * 16, store->end) != (cnt + 1) * 16)
    {
      perror("pwrite new slotarea");
      free(slots);
      return 0;
    }
  free(slots);
  store->slotsoffset = store->end;
  store->end += (cnt + 1) * 16;
  store->freecnt = cnt;
  store->usedcnt = 0;
  return 1;
}

/* 
 * add a new block to the store.
 * returns the store offset, 0 on error
 */
static unsigned long long
putinstore(struct deltastore *store, unsigned char *buf, int size, unsigned char *md5, unsigned int hx)
{
  unsigned char md5buf[16];
  unsigned char hp[16];
  unsigned long long offset;

  unsigned char *hash;
  unsigned int h, hh, hm;

  if (!size || size > DELTA_BSIZE)
    return 0;

  if (store->rdonly)
    return 0;
  if (store->freecnt == 0 && !addslotarea(store, SLOTS_PER_AREA))
    return 0;

  /* write data */
  offset = store->end;
  if (offset + size >= (1LL << 48))
    return 0;			/* store too big! */
  if (pwrite(store->fd, buf, size, store->end) != size)
    {
      perror("pwrite data");
      return 0;
    }
  adddataarea(store, store->end, store->end + size);
  store->end += size;

  /* write slot */
  if (!md5)
    {
      md5block(buf, size, md5buf);
      md5 = md5buf;
    }
  hp[0] = size >> 8;
  hp[1] = size;
  putu48(hp + 2, offset);
  if (size == DELTA_BSIZE)
    {
      if (!hx)
        hx = buzhash(buf);
      putu32(hp + 8, hx);
      memcpy(hp + 12, md5, 4);
    }
  else
    {
      hp[0] |= 0x80;		/* small block marker */
      memcpy(hp + 8, md5, 8);
      hx = getu32(hp + 8);	/* needed later */
    }
#if 0
{
  int j;
  printf("NEW SLOT");
  for (j = 0; j < 16; j++)
    printf(" %02x", hp[j]);
  printf("\n");
}
#endif
  if (pwrite(store->fd, hp, 16, store->slotsoffset + (store->usedcnt + 1) * 16) != 16)
    {
      perror("pwrite slot");
      return 0;
    }
  store->freecnt--;
  store->usedcnt++;

  /* update hash */
  hm = store->hm;
  hash = store->hash;
  h = hx & hm;
  hh = HASHCHAIN_START;
  while (hash[16 * h] != 0)
    h = HASHCHAIN_NEXT(h, hh, hm);
  memcpy(hash + 16 * h, hp, 16);
  store->hf++;
  return offset;
}

/* make sure that we found the correct block */
static int
checkstore(struct deltastore *store, unsigned long long offset, unsigned char *buf, int size)
{
  unsigned char buf2[4096];
  while (size)
    {
      int l = size > 4096 ? 4096 : size;
      if (pread(store->fd, buf2, l, offset) != l)
	return 0;
      if (memcmp(buf2, buf, l) != 0)
	return 0;
      size -= l;
      buf += l;
      offset += l;
    }
  return 1;
}

/* 
 * try to find a (non-rolling) block in the store. If not found, add it.
 * returns the store offset, 0 on error
 */
static unsigned long long
reuse_or_add_block(struct deltastore *store, unsigned char *buf, int size)
{
  unsigned char md5[16];
  unsigned int h, hh, hm;
  unsigned char *hash;
  unsigned long long offset;

  if (!size || size >= DELTA_BSIZE)
    return 0;		/* only small non-rolling blocks for now */
  md5block(buf, size, md5);
  hm = store->hm;
  hash = store->hash;
  h = (md5[0] << 24 | md5[1] << 16 | md5[2] << 8 | md5[3]) & hm;
  hh = HASHCHAIN_START;
  while (hash[16 * h] != 0)
    {
      unsigned char *hp = hash + 16 * h;
      if (((hp[0] & 0x7f) << 8 | hp[1]) == size && !memcmp(hp + 8, md5, 8))
	{
	  offset = getu48(hp + 2);
	  if (checkstore(store, offset, buf, size))
	    return offset;
	}
      h = HASHCHAIN_NEXT(h, hh, hm);
    }
  return putinstore(store, buf, size, md5, 0);
}

/**
 **  block encoding
 **/

static int
encodelonglong(FILE *ofp, unsigned long long x)
{
  unsigned long long z = 1;
  int c;
  do
    {
      z = z << 7 | (x & 127);
      x >>= 7;
    }
  while (x);
  for (;;)
    {
      c = (z & 127) | 128;
      z >>= 7;
      if (z == 1)
	break;
      if (putc(c, ofp) == EOF)
	return 0;
    }
  if (putc(c ^ 128, ofp) == EOF)
    return 0;
  return 1;
}

static int
encodelonglong_mem(unsigned char *bp, unsigned long long x)
{
  unsigned long long z = 1;
  int c;
  int l = 0;
  do
    {
      z = z << 7 | (x & 127);
      x >>= 7;
    }
  while (x);
  for (;;)
    {
      c = (z & 127) | 128;
      z >>= 7;
      if (z == 1)
	break;
      *bp++ = c;
      l++;
    }
  *bp = c ^ 128;;
  return l + 1;
}


#if 1
/* fancy delta conversion, seems to work better than the simple xor */
static inline unsigned long long
encodeoffset(unsigned long long oldoffset, unsigned long long offset)
{
  if (oldoffset & (1LL << 47))
    {
      offset ^= ((1LL << 48) - 1);
      oldoffset ^= ((1LL << 48) - 1);
    }
  if (offset < oldoffset * 2)
    {
      if (offset < oldoffset)
	offset = (oldoffset - offset - 1) << 1 | 1;
      else
	offset = (offset - oldoffset) << 1;
    }
  return offset;
}

static inline unsigned long long
decodeoffset(unsigned long long oldoffset, unsigned long long offset)
{
  int neg = oldoffset & (1LL << 47) ? ((1LL << 48) - 1) : 0;
  oldoffset ^= neg;
  if (offset < oldoffset * 2)
    {
      if (offset & 1)
	offset = oldoffset - ((offset >> 1) + 1);
      else
	offset = oldoffset + (offset >> 1);
    }
  return offset ^ neg;
}

#else
static inline unsigned long long
encodeoffset(unsigned long long oldoffset, unsigned long long offset)
{
  return oldoffset ^ offset;
}

static inline unsigned long long
decodeoffset(unsigned long long oldoffset, unsigned long long offset)
{
  return oldoffset ^ offset;
}
#endif

static int
flushoutbuf(struct deltaout *out)
{
  if (!out->outbuf_len)
    return 1;
  if (out->outbuf_len >= MAX_BSIZE_META)
    return 0;

  if (out->outbuf_len >= MIN_BSIZE_META)
    {
      /* put as meta block into store! */
      int size = out->outbuf_len;
      unsigned long long offset;
#if 0
      printf("META size %d\n", out->outbuf_len);
#endif
      offset = reuse_or_add_block(out->store, out->outbuf, size);
      if (!offset)
	return 0;
      /* encode meta block into outbuf */
      if (out->outbuf_startoffset_set)
	out->lastoffset = out->outbuf_startoffset;
      out->outbuf[0] = 15;			/* meta */
      out->outbuf_len = 1;
      out->outbuf_len += encodelonglong_mem(out->outbuf + out->outbuf_len, size);
      out->outbuf_len += encodelonglong_mem(out->outbuf + out->outbuf_len, encodeoffset(out->lastoffset, offset));
      out->lastoffset = offset + size;
      out->outbuf_startoffset_set = 0;
    }

  if (out->outbuf_startoffset_set)
    {
      /* tricky: fix up first offset! */
      unsigned char buf[9];
      int l = encodelonglong_mem(buf, out->outbuf_set_offset);
      if (fwrite(out->outbuf, out->outbuf_set_len1, 1, out->fp) != 1)
	return 0;
      if (fwrite(buf, l, 1, out->fp) != 1)
	return 0;
      if (out->outbuf_set_len2 < out->outbuf_len && fwrite(out->outbuf + out->outbuf_set_len2, out->outbuf_len - out->outbuf_set_len2, 1, out->fp) != 1)
	return 0;
    }
  else if (fwrite(out->outbuf, out->outbuf_len, 1, out->fp) != 1)
    return 0;
  out->outbuf_len = 0;
  out->outbuf_startoffset_set = 0;
  return 1;
}

static int
encodestoreblock_real(struct deltaout *out, unsigned long long offset, unsigned long long size)
{
#if 0
  printf("BLOCK %#llx %llu\n", offset, size);
#endif
  if (out->outbuf_do_meta)
    {
      int lastlen = out->outbuf_len;
      /* the following code is needed as we want to use a lastoffset of
       * zero if this ends up in a meta instruction. So we encode with
       * lastoffset zero but also store the real lastoffset and byte offsets,
       * in order to fix up the offset in flushbuf */
      int set = out->outbuf_startoffset_set;
      if (!set)
	{
	  out->outbuf_startoffset_set = 1;
	  out->outbuf_startoffset = out->lastoffset;
	  out->outbuf_set_offset = encodeoffset(out->lastoffset, offset);
	  out->lastoffset = 0;
	}
      out->outbuf_len += encodelonglong_mem(out->outbuf + out->outbuf_len, out->oldsize + 256);
      if (!set)
        out->outbuf_set_len1 = out->outbuf_len;
      out->outbuf_len += encodelonglong_mem(out->outbuf + out->outbuf_len, encodeoffset(out->lastoffset, offset));
      if (!set)
        out->outbuf_set_len2 = out->outbuf_len;

      if (out->outbuf_len >= DELTA_BSIZE)
	{
	  /* buffer too full. revert changes. flush outbuf. retry */
	  out->outbuf_len = lastlen;
	  if (!set)
	    {
	      out->outbuf_startoffset_set = 0;
	      out->lastoffset = out->outbuf_startoffset;
	    }
	  if (!flushoutbuf(out))
	    return 0;
	  return encodestoreblock_real(out, offset, size);
	}
    }
  else
    {
      if (!encodelonglong(out->fp, size + 256))
	return 0;
      if (!encodelonglong(out->fp, encodeoffset(out->lastoffset, offset)))
	return 0;
    }
  out->lastoffset = offset + size;
  return 1;
}

/* encode a store block instruction
 * we delay the real encoding so that we can join adjacent blocks
 */
static int
encodestoreblock(struct deltaout *out, unsigned long long offset, unsigned long long size)
{
  if (out->oldoffset)
    {
      if (out->oldoffset + out->oldsize == offset)
	{
	  out->oldsize += size;
	  return 1;
	}
      if (!encodestoreblock_real(out, out->oldoffset, out->oldsize))
        return 0;
    }
  out->oldoffset = offset;	/* block not yet written */
  out->oldsize = size;
  return 1;
}

/* encode a direct data instruction
 */
static int
encodedirect(struct deltaout *out, unsigned char *buf, int size)
{
  if (!size)
    return 1;
  if (size >= 256 - 16)
    return 0;
  if (out->oldoffset)
    {
      if (!encodestoreblock(out, 0, 0))	/* flush */
	return 0;
    }
#if 0
  printf("DIRECT %u\n", size);
#endif
  if (out->outbuf_do_meta)
    {
      if (out->outbuf_len + 1 + size >= DELTA_BSIZE)
	{
	  /* buffer too full. flush outbuf */
	  if (!flushoutbuf(out))
	    return 0;
	}
      out->outbuf[out->outbuf_len++] = 16 + size;
      memcpy(out->outbuf + out->outbuf_len, buf, size);
      out->outbuf_len += size;
    }
  else
    {
      if (putc(16 + size, out->fp) == EOF)
	return 0;
      if (fwrite(buf, size, 1, out->fp) != 1)
	return 0;
    }
  return 1;
}

/**
 **  the delta algorithm
 **/

static unsigned long long
extendblock(struct deltastore *store, FILE *fp, unsigned long long offset, unsigned long long areaend, unsigned long long maxextend)
{
  unsigned char buf[1024];
  int c, i, bufl;
  unsigned long long extend = 0;

  if (offset >= areaend)
    return 0;
  if (areaend - offset < maxextend)
    maxextend = areaend - offset;
  if (!maxextend)
    return 0;
  i = bufl = 0;
  for (;;)
    {
      if (i == bufl)
	{
	  bufl = maxextend > 1024 ? 1024 : maxextend;
	  if (bufl == 0)
	    return extend;
	  if (pread(store->fd, buf, bufl, (off_t)offset) != bufl)
	    return extend;
	  offset += bufl;
	  maxextend -= bufl;
	  i = 0;
	}
      c = getc(fp);
      if (c == EOF)
	return extend;
      if (buf[i++] != c)
	{
	  ungetc(c, fp);
	  return extend;
	}
      extend++;
    }
}

static unsigned long long
extendblock_back(struct deltastore *store, unsigned char *data, unsigned long long offset, unsigned long long areastart, unsigned long long maxextend)
{
  unsigned char buf[1024];
  unsigned long long extend = 0;
  int bufl;

  if (offset <= areastart)
    return 0;
  if (offset - areastart < maxextend)
    maxextend = offset - areastart;
  if (!maxextend)
    return 0;
  bufl = 0;
  for (;;)
    {
      if (bufl == 0)
	{
	  bufl = maxextend > 1024 ? 1024 : maxextend;
	  if (bufl == 0)
	    return extend;
	  offset -= bufl;
	  if (pread(store->fd, buf, bufl, (off_t)offset) != bufl)
	    return extend;
	  maxextend -= bufl;
	}
      if (*--data != buf[--bufl])
	return extend;
      extend++;
    }
}

static int
dosimple(struct deltastore *store, struct deltaout *out, unsigned char *buf, int size)
{
  unsigned long long offset;

  while (size >= DELTA_BSIZE)
    {
      offset = putinstore(store, buf, DELTA_BSIZE, 0, 0);
      if (!offset || !encodestoreblock(out, offset, DELTA_BSIZE))
	return 0;
      size -= DELTA_BSIZE;
      buf += DELTA_BSIZE;
    }
  if (size < MIN_BSIZE)
    return encodedirect(out, buf, size);
  offset = reuse_or_add_block(store, buf, size);
  if (!offset)
    return 0;
  return encodestoreblock(out, offset, size);
}

static int
dodelta(struct deltastore *store, FILE *fp, struct deltaout *out, unsigned long long size)
{
  unsigned char buf[DELTA_BSIZE * 16];
  unsigned char md5[16];
  unsigned long long offset, extendf, extendb;
  unsigned int h, hh, hm, hx;
  unsigned char *hash;
  int c, foundit, bi;

#if 0
  printf("DODELTA\n");
#endif
  hm = store->hm;
  hash = store->hash;
  while (size)
    {
      if (size < DELTA_BSIZE)
	{
	  if (fread(buf, (int)size, 1, fp) != 1)
	    return 0;
	  if (!dosimple(store, out, buf, (int)size))
	    return 0;
	  break;
	}
      /* read a block */
      bi = 0;
      if (fread(buf, DELTA_BSIZE, 1, fp) != 1)
	return 0;
      size -= DELTA_BSIZE;

      hx = buzhash(buf);
      foundit = 0;

      /* start rolling */
      for (;;)
	{
	  int md5set = 0;
	  /* check if the block at (buf + bi) is in the hash */
#if 0
	  if (hx != buzhash(buf + bi))
	    abort();
#endif
	  hh = HASHCHAIN_START;
	  for (h = hx & hm; hash[16 * h] != 0; h = HASHCHAIN_NEXT(h, hh, hm))
	    {
	      unsigned char *hp = hash + 16 * h;
	      /* first check block len */
	      if (hp[0] != (DELTA_BSIZE >> 8) || hp[1] != (DELTA_BSIZE & 0xff))
		continue;
	      /* then check complete hash value */
	      if (hp[8] != (hx >> 24))
		continue;
	      if ((hp[8] << 24 | hp[9] << 16 | hp[10] << 8 | hp[11]) != hx)
		continue;
	      /* then check strong hash */
	      if (!md5set)
		{
		  md5block(buf + bi, DELTA_BSIZE, md5);
		  md5set = 1;
		}
	      if (memcmp(hp + 12, md5, 4) != 0)
		continue;
	      /* looks good. check data */
	      offset = getu48(hp + 2);
	      if (!checkstore(store, offset, buf + bi, DELTA_BSIZE))
		continue;
	      /* yes! found block in store! */
	      /* try to extend found block */
	      c = finddataarea(store, offset);
	      extendf = extendb = 0;
	      if (c >= 0)
		{
		  extendf = extendblock(store, fp, offset + DELTA_BSIZE, store->offsets[c + 1], size);
		  size -= extendf;	/* extended bytes */
		  extendb = extendblock_back(store, buf + bi, offset, store->offsets[c], bi);
		  offset -= extendb;
		  bi -= extendb;
		}
	      /* encode data before block */
	      if (bi)
		{
		  if (!dosimple(store, out, buf, bi))
		    return 0;
		  bi = 0;
		}
	      /* encode */
	      if (!encodestoreblock(out, offset, DELTA_BSIZE + extendf + extendb))
		return 0;
	      foundit = 1;
	      break;
	    }
	  if (foundit)
	    break;

          /* not found. move block one byte */
	  if (!size)
	    {
	      if (!dosimple(store, out, buf, bi + DELTA_BSIZE))
		return 0;
	      break;
	    }
	  c = fgetc(fp);
	  if (c == EOF)
	    return 0;
	  size--;
	  buf[DELTA_BSIZE + bi] = c;
	  hx = (hx << 1) ^ (hx & (1 << 31) ? 1 : 0) ^ buz_noise[c];
	  c = buf[bi++];
	  hx ^= buz_noise[c] ^ (0x83d31df4U ^ 0x07a63be9U);
	  if (bi == sizeof(buf) - DELTA_BSIZE)
	    {
	      /* trim down, but leave one block for backward extension */
	      if (!dosimple(store, out, buf, bi - DELTA_BSIZE))
		return 0;
	      /* no overlap as the buffer is >= 4 * DELTA_BSIZE */
	      memcpy(buf, buf + bi - DELTA_BSIZE, 2 * DELTA_BSIZE);
	      bi = DELTA_BSIZE;
	    }
	}
    }
  if (!encodestoreblock(out, 0, 0))	/* flush */
    return 0;
  if (!flushoutbuf(out))
    return 0;
  return 1;
}

static int
readdeltastore(struct deltastore *store, int fd, int rdonly, unsigned long long xsize)
{
  unsigned char *slots;
  unsigned char oneslot[16];
  unsigned long long offset, nextoffset, lastgoodoffset;
  struct stat st;
  unsigned long long fsize;
  unsigned int nslots = 0, hslots;
  unsigned char *hash;
  unsigned int hm, h, hh, hf, hd;
  int isbad = 0;
  int i, lasti, cnt, maxcnt = 0;
  unsigned int drop = 0;

  memset(store, 0, sizeof(*store));
  store->fd = fd;
  store->rdonly = rdonly;
  if (fstat(fd, &st))
    {
      perror("fstat");
      return 0;
    }
  fsize = (unsigned long long)st.st_size;
  store->end = fsize;

  /* first pass: find number of used entries */
  offset = 0;
  lastgoodoffset = -1;
  for (;;)
    {
      if (offset == fsize)
	break;
      if (offset + 16 > fsize)
	{
	  fprintf(stderr, "WARNING: slot area exceeds file size!\n");
	  isbad = 1;
	  break;
	}
      if (pread(fd, oneslot, 16, offset) != 16)
	return 0;
      if (memcmp(oneslot, "OBSDELT", 8) != 0)
	{
	  fprintf(stderr, "WARNING: slot magic error!\n");
	  isbad = 1;
	  break;
	}
      cnt = oneslot[8] << 8 | oneslot[9];
      nextoffset = getu48(oneslot + 10);
      if (!nextoffset)
	nextoffset = fsize;
      offset += (cnt + 1) * 16;
      if (offset > fsize)
	{
	  fprintf(stderr, "WARNING: slot area exceeds file size!\n");
	  isbad = 1;
	  break;
	}
      nslots += cnt;
      lastgoodoffset = offset - (cnt + 1) * 16;
      if (cnt > maxcnt)
	maxcnt = cnt;
      if (offset > nextoffset)
	{
	  fprintf(stderr, "WARNING: end of slots bigger than nextoffset!\n");
	  isbad = 1;
	  break;
	}
      offset = nextoffset;
    }

  if (isbad && !store->rdonly)
    {
      fprintf(stderr, "WARNING: fixing up bad slots!\n");
      if (lastgoodoffset == -1)
	{
	  /* worst case: first slots area is damaged */
	  memset(oneslot, 0, 16);
	  memcpy(oneslot, "OBSDELT", 8);
	  putu48(oneslot + 10, fsize);
	  if (pwrite(store->fd, oneslot, 16, 0) != 16)
	    {
	      perror("pwrite repair first slots area");
	      return 0;
	    }
	}
      else
	{
	  putu48(oneslot + 10, fsize);
	  if (pwrite(store->fd, oneslot + 10, 6, lastgoodoffset + 10) != 6)
	    {
	      perror("pwrite repair bad slots area nextoffset");
	      return 0;
	    }
	}
      isbad = 0;
    }

  slots = calloc(maxcnt + 1, 16);
  if (!slots)
    return 0;

  /* find good hash size and allocate hash */
  hslots = nslots + xsize / 512;
  while (hslots & (hslots - 1))
    hslots = hslots & (hslots - 1);
  if (hslots < 16384)
    hslots = 16384;		/* 1 MByte min mem */
  while (hslots > 128 * 1024 * 1024)	/* 8 GByte max mem */
    {
      /* oh no. max size reached. drop half of slots */
      hslots >>= 1;
      drop += (drop ? drop : nslots) / 2;
    }
  hslots *= 4;
  store->hm = hm = hslots - 1;
  store->hash = hash = calloc(hm + 1, 16);
  if (!hash)
    {
      fprintf(stderr, "could not allocate hash (%u MB)\n", (hm + 1) / (1024 * 1024 / 16));
      free(slots);
      return 0;
    }

  /* second pass: fill the hash */
  offset = 0;
  hf = hd = 0;
  for (;;)
    {
      int toread = 16 * (maxcnt + 1);
      if (isbad && lastgoodoffset == -1)
	break;
      if (offset >= fsize)
	break;
      if (offset + toread > fsize)
	toread = fsize - offset;
      if (pread(fd, slots, toread, offset) != toread)
	{
	  free(slots);
	  return 0;
	}
      if (memcmp(slots, "OBSDELT", 8) != 0)
	break;
      cnt = oneslot[8] << 8 | oneslot[9];
      offset += 16 * (cnt + 1);
      nextoffset = getu48(slots + 10);
      if (!nextoffset)
	nextoffset = fsize;
      if (offset > nextoffset)
	break;
      if (offset != nextoffset)
	adddataarea(store, offset, nextoffset);
      lasti = 0;
      for (i = 1; i < cnt + 1; i++)
	if (slots[16 * i])
	  {
	    unsigned char *hp = slots + 16 * i;
	    int len = (hp[0] & 127) << 8 | hp[1];
	    unsigned long long o = getu48(hp + 2);
	    lasti = i;
	    if (drop)
	      {
		drop--;
		hd++;
	      }
	    else if (o >= offset && o + len <= nextoffset)
	      {
		/* a good one. add to hash. */
	        h = getu32(hp + 8) & hm;
		hh = HASHCHAIN_START;
		while (hash[16 * h] != 0)
		  h = HASHCHAIN_NEXT(h, hh, hm);
		memcpy(hash + 16 * h, hp, 16);
		hf++;
	      }
	  }
      store->slotsoffset = offset - 16 * (cnt + 1);
      store->freecnt = cnt - lasti;
      store->usedcnt = lasti;
      if (isbad && lastgoodoffset == store->slotsoffset)
	break;
      offset = nextoffset;
    }
  store->hf = hf;
  store->hd = hd;
#if 0
  printf("readdeltastore: have %d entries, %d dropped, hash size %d\n", hf, hd, hm + 1);
#endif
  free(slots);
  return 1;
}

static void
printdeltastorestats(struct deltastore *store)
{
  unsigned int buckets[2048];
  unsigned int hm, hf, hd;
  unsigned char *hp;
  int i, j, bc = 16;

  memset(buckets, 0, sizeof(buckets));
  hm = store->hm;
  hf = store->hf;
  hd = store->hd;

  printf("store size: %llu (%u MB)\n", store->end, (unsigned int)(store->end / (1024 * 1024)));
  printf("hash mask: 0x%x (%u MB hash mem)\n", hm, (unsigned int)(hm / 65536) + 1);
  printf("hash entries set: %u (%.2f %%)\n", hf, ((double)hf * 100) / ((double)hm + 1));
  printf("hash entries dropped: %u (%.2f %%)\n", hd, hd ? ((double)hd * 100) / ((double)hf + (double)hd) : 0.);
  for (hp = store->hash;; hp += 16)
    {
      if (hp[0])
        buckets[((hp[0] & 0x7f) << 8 | hp[1]) / 16]++;
      if (!hm--)
	break;
    }
  for (i = 2047; i >= 1; i--)
    if (buckets[i])
      break;
  i++;
  while (i > 16)
    {
      for (j = 0; j < i; j += 2)
	buckets[j / 2] = buckets[j] + buckets[j + 1];
      i = (i + 1) / 2;
      bc *= 2;
    }
  printf("block stats:\n");
  for (j = 0; j < i; j++)
    printf("  size %#6x - %#6x: %10u\n", j * bc, j * bc + bc - 1, buckets[j]);
  printf("data areas: %d\n", store->noffsets / 2);
}

static void
freedeltastore(struct deltastore *store)
{
  if (store->hash)
    free(store->hash);
  if (store->offsets)
    free(store->offsets);
}

static void
settimes(int fd, struct stat *st)
{
  struct timeval tv[2];

  tv[0].tv_sec = st->st_atime;
  tv[0].tv_usec = 0;
  tv[1].tv_sec = st->st_mtime;
  tv[1].tv_usec = 0;
  futimes(fd, tv);
}

static int
checkhexcomp(unsigned char *buf)
{
  int i, hexcomp = 0;
  for (i = 0; i < 110; i++)
    {
      int c = *buf++;
      if (c >= '0' && c <= '9')
	continue;
      else if (c >= 'A' && c <= 'F')
	{
	  if (!hexcomp)
	    hexcomp = 1;
	  if (hexcomp != 1)
	    break;
	}
      else if (c >= 'a' && c <= 'f')
	{
	  if (!hexcomp)
	    hexcomp = 2;
	  if (hexcomp != 2)
	    break;
	}
      else
	break;
    }
  if (i < 110)
    return 0;
  return hexcomp ? hexcomp : 1;
}

static unsigned int fromhex(unsigned char *hex)
{
  int i;
  unsigned int x = 0;
  for (i = 0; i < 8; i++, hex++)
    {
      if (*hex >= '0' && *hex <= '9')
	x = x << 4 | (*hex - '0');
      else if (*hex >= 'a' && *hex <= 'f')
	x = x << 4 | (*hex - ('a' - 10));
      else if (*hex >= 'A' && *hex <= 'F')
	x = x << 4 | (*hex - ('A' - 10));
    }
  return x;
}

static void
magic_inode_increment(unsigned char *cpio)
{
  unsigned int inode = getu32(cpio + 3);
  if (inode)
    putu32(cpio + 3, inode + 1);
}

static int
makedelta(struct deltastore *store, FILE *fp, FILE *ofp, unsigned long long fpsize)
{
  unsigned char cpiohead[1024 + 16384];
  unsigned char oldcpio[1024];
  int trailerseen = 0;
  int i, j;
  struct deltaout out;

  if (fpsize >= (1LL << 40))
    return 0;

  /* init deltaout struct */
  memset(&out, 0, sizeof(out));
  out.fp = ofp;
  out.store = store;
  out.outbuf_do_meta = 1;		/* create meta blocks */

  /* write our header */
  memset(cpiohead, 0, 32);
  memcpy(cpiohead, "OBScpio", 8);
  putu48(cpiohead + 10, fpsize);
  if (fwrite(cpiohead, 16, 1, ofp) != 1)
    return 0;

  memset(oldcpio, 0, 1024);
  while (!trailerseen)
    {
      unsigned long long fsize;
      unsigned int hsize, nsize;
      int run;
      int hexcomp;
      int noff = 110;
      int zero;

      /* read the header */
      if (fread(cpiohead, 110, 1, fp) != 1)
	{
	  fprintf(stderr, "cpio header read error\n");
	  return 0;
	}
      if (memcmp(cpiohead, "070701", 6) != 0)
	{
	  fprintf(stderr, "not a newc cpio archive\n");
	  return 0;
	}
      fsize = fromhex(cpiohead + 54);
      nsize = fromhex(cpiohead + 94);
      if (nsize > 16384)
	{
	  fprintf(stderr, "filename size too big\n");
	  return 0;
	}
      hsize = noff + nsize;
      if (hsize & 3)
	hsize += 4 - (hsize & 3);
      /* check if we can do hex compression */
      hexcomp = checkhexcomp(cpiohead);
      if (hexcomp)
	{
	  /* do fancy hex compression */
	  cpiohead[0] = 0x07;
	  cpiohead[1] = 0x07;
	  cpiohead[2] = 0x01;
	  for (i = 3; i < 55; i += 4)
	    {
	      unsigned int x = fromhex(cpiohead + i * 2);
	      putu32(cpiohead + i, x);
	    }
	   noff -= 55;
	   hsize -= 55;
	}

#if 0
      printf("fsize = %d, nsize = %d, hsize = %d\n", fsize, nsize, hsize);
#endif
      if (fread(cpiohead + noff, hsize - noff, 1, fp) != 1)
	{
	  fprintf(stderr, "cpio header read error\n");
	  return 0;
	}
      if (fsize == 0 && nsize == 11 && !memcmp(cpiohead + noff, "TRAILER!!!", 11))
	{
	  trailerseen = 1;
	  while (hsize < sizeof(cpiohead))
	    {
	      int c = getc(fp);
	      if (c == EOF)
		break;
	      cpiohead[hsize++] = c;
	    }
	  if (hsize == sizeof(cpiohead))
	    {
	      fprintf(stderr, "excess trailer data\n");
	      return 0;
	    }
	}
      /* check trailing zero */
      for (zero = 0; zero < 4; zero++)
	if (cpiohead[hsize - 1 - zero] != 0)
	  break;
      /* write the header */
      if (putc(2 + hexcomp, ofp) == EOF)
	return 0;
      for (i = 0; i < 1024 && i < hsize; i++)
	{
	  cpiohead[i] ^= oldcpio[i];
	  oldcpio[i] ^= cpiohead[i];
	}
      if (hexcomp)
	magic_inode_increment(oldcpio);
      run = 0;
      hsize -= zero;
      for (i = 0; i < hsize; i++)
	{
	  if (cpiohead[i] == 0)
	    {
	      run++;
	      if (i + 1 < hsize)
	        continue;
	    }
	  while (run)
	    {
	      int z = run > 127 ? 127 : run;
	      if (putc(z, ofp) == EOF)
		return 0;
	      run -= z;
	    }
	  if (cpiohead[i] == 0)
	    break;		/* ended in zero */
	  for (j = i; j < hsize - 1; j++)
	    if (cpiohead[j] == 0 && cpiohead[j + 1] == 0)
	      break;
	  if (j == hsize - 1)
	    j = hsize;
	  j -= i;
	  if (j > 123)
	    j = 123;
	  if (putc(j + 128, ofp) == EOF)
	    return 0;
	  while (j-- > 0)
	    {
	      int z = cpiohead[i++];
	      if (putc(z, ofp) == EOF)
		return 0;
	    }
	  i--;
	}
      if (putc(zero ? zero + 251 : 0, ofp) == EOF)
	return 0;
      if (fsize)
	{
	  if (!dodelta(store, fp, &out, fsize))
	    return 0;
	  if ((fsize & 3) != 0)
	    {
	      i = 4 - (fsize & 3);
	      if (putc(4 + i, ofp) == EOF)
		return 0;
	      while (i--)
		{
		  if (getc(fp) != 0)
		    {
		      fprintf(stderr, "non-zero padding\n");
		      return 0;
		    }
		}
	    }
	}
    }
  if (putc(1, ofp) == EOF)
    return 0;
  if (fflush(ofp) != 0)
    return 0;
  return 1;
}

static unsigned long long
expandobscpio_next(FILE *fp)
{
  unsigned long long x = 0;
  int i;
  for (;;)
    {
      i = getc(fp);
      if (i == EOF)
	return (unsigned long long)(-1);
      if ((i & 128) == 0)
	return x << 7 | i;
      x = x << 7 | (i ^ 128);
    }
}

static unsigned long long
expandobscpio_next_mem(unsigned char **bp, unsigned int *lp)
{
  unsigned long long x = 0;
  unsigned char *b = *bp;
  unsigned int l = *lp;
  int i;
  for (;;)
    {
      if (l == 0)
	return (unsigned long long)(-1);
      i = *b++;
      l--;
      if ((i & 128) == 0)
        {
	  *bp = b;
	  *lp = l;
	  return x << 7 | i;
        }
      x = x << 7 | (i ^ 128);
    }
}

static int
expandobscpio_direct_mem(unsigned char **bp, unsigned int *lp, void *out, unsigned int outlen)
{
  if (*lp < outlen)
    return 0;
  if (outlen)
    memcpy(out, *bp, outlen);
  *bp += outlen;
  *lp -= outlen;
  return 1;
}

static int
expandcpiohead(FILE *fp, FILE *ofp, unsigned char *cpio, int hexcomp)
{
  int l = 0;
  int zero;
  for (;;)
    {
      int c = getc(fp);
      if (c == EOF)
	return 0;
      if (c == 0)
	break;
      if (c < 128)
	zero = 1;
      else if (c >= 252)
	{
	  zero = -1;
	  c -= 251;
	}
      else
	{
	  zero = 0;
	  c -= 128;
	}
      while (c-- > 0)
	{
	  int x = zero ? 0 : getc(fp);
	  if (x == EOF)
	    return 0;
	  if (l < 1024)
	    {
	      if (zero >= 0)
	        x ^= cpio[l];
	      cpio[l++] = x;
	    }
	  if (hexcomp && l <= 55)
	    {
	      int lettershift = (hexcomp == 1 ? 'A' : 'a') - ('0' + 10);
	      int x1 = (x >> 4) + '0';
	      int x2 = (x & 15) + '0';
	      if (x1 > '9')
		x1 += lettershift;
	      if (x2 > '9')
		x2 += lettershift;
	      if (putc(x1, ofp) == EOF || putc(x2, ofp) == EOF)
	        return 0;
	    }
	  else if (putc(x, ofp) == EOF)
	    return 0;
	}
      if (zero < 0)
	break;
    }
  if (hexcomp)
    magic_inode_increment(cpio);
  return 1;
}

static int
expandobscpio(FILE *fp, int fdstore, FILE *ofp)
{
  unsigned char magic[16];
  unsigned char metabuf[16384];
  unsigned char cpio[1024];
  unsigned long long o, l;
  struct stat st;
  unsigned long long oldoffset = 0;
  unsigned char *meta = 0;
  unsigned int metal = 0;
  unsigned long long oldoffset_meta = 0;

  if (!fp || !ofp || fdstore == -1)
    return 0;
  if (fstat(fileno(fp), &st))
    return 0;
  if (fread(magic, 16, 1, fp) != 1 || memcmp(magic, "OBScpio", 7) != 0)
    return 0;
  memset(cpio, 0, sizeof(cpio));
  for (;;)
    {
      if (meta && !metal)
	{
          meta = 0;
	  oldoffset = oldoffset_meta;
	}
      if (meta)
        l = expandobscpio_next_mem(&meta, &metal);
      else
        l = expandobscpio_next(fp);
      if (l == (unsigned long long)(-1))
	return 0;
#if 0
printf("NEXT %d\n", l);
#endif
      if (l < 16)
	{
	  /* first 16 reserved as instructions */
	  if (meta)
	    return 0;
	  if (l == 1)					/* EOF */
	    break;
	  if (l == 2 || l == 3 || l == 4)		/* CPIO */
	    {
	      if (!expandcpiohead(fp, ofp, cpio, l - 2))
		return 0;
	    }
	  else if (l == 5 || l == 6 || l == 7)		/* ZERO */
	    {
	      l -= 4;
	      while (l--)
	        if (putc(0, ofp) == EOF)
		  return 0;
	    }
	  else if (l == 15)				/* META */
	    {
	      l = expandobscpio_next(fp);
	      if (l == (unsigned long long)(-1))
		return 0;
	      if (l < 16 || l > sizeof(metabuf))
		return 0;
	      o = expandobscpio_next(fp);
	      if (o == (unsigned long long)(-1))
		return 0;
	      o = decodeoffset(oldoffset, o);
	      oldoffset_meta = o + l;
	      oldoffset = 0;
	      if (pread(fdstore, metabuf, (size_t)l, (off_t)o) != (size_t)l)
		return 0;
	      metal = (unsigned int)l;
	      meta = metabuf;
	    }
	  else
	    return 0;
	}
      else if (l < 256)
	{
	  /* direct bytes */
	  l -= 16;
	  if (l)
	    {
	      char buf[256];
	      if (meta)
		{
		  if (expandobscpio_direct_mem(&meta, &metal, buf, l) != 1)
		    return 0;
		}
	      else if (fread(buf, (int)l, 1, fp) != 1)
	        return 0;
	      if (fwrite(buf, (int)l, 1, ofp) != 1)
	        return 0;
	    }
	}
      else
	{
	  /* bytes from the store */
	  l -= 256;
	  if (meta)
	    o = expandobscpio_next_mem(&meta, &metal);
	  else
	    o = expandobscpio_next(fp);
	  if (o == (unsigned long long)(-1))
	    return 0;
	  o = decodeoffset(oldoffset, o);
	  oldoffset = o + l;
	  while (l)
	    {
	      char buf[8192];
	      size_t count = l > 8192 ? 8192 : l;
	      if (pread(fdstore, buf, count, (off_t)o) != count)
	        return 0;
	      if (fwrite(buf, count, 1, ofp) != 1)
	        return 0;
	      o += count;
	      l -= count;
	    }
	}
    }
  if (fflush(ofp) != 0)
    return 0;
  settimes(fileno(ofp), &st);
  return 1;
}

static void
printobscpioinstr(FILE *fp, int fdstore, int withmeta)
{
  unsigned char magic[16];
  unsigned long long oldoffset = 0, o, l;
  unsigned char metabuf[16384];
  unsigned char *meta = 0;
  unsigned int metal = 0;
  unsigned long long oldoffset_meta = 0;

  unsigned int stats_cpio = 0;
  unsigned long long stats_cpio_len = 0;
  unsigned int stats_direct = 0;
  unsigned long long stats_direct_len = 0;
  unsigned int stats_store = 0;
  unsigned long long stats_store_len = 0;
  unsigned int stats_zero = 0;
  unsigned long long stats_zero_len = 0;
  unsigned int stats_meta = 0;
  unsigned long long stats_meta_len = 0;
  unsigned int stats_meta_store = 0;
  unsigned long long stats_meta_store_len = 0;
  unsigned int stats_meta_direct = 0;
  unsigned long long stats_meta_direct_len = 0;

  if (fread(magic, 16, 1, fp) != 1 || memcmp(magic, "OBScpio", 7) != 0)
    return;
  for (;;)
    {
      if (meta && !metal)
	{
          meta = 0;
	  oldoffset = oldoffset_meta;
	}
      if (meta)
        l = expandobscpio_next_mem(&meta, &metal);
      else
        l = expandobscpio_next(fp);
      if (l == (unsigned long long)(-1))
        return;
      if (l < 16)
	{
	  if (meta)
	    return;
	  if (l == 1)
	    {
	      printf("end\n");
	      break;
	    }
	  if (l == 2 || l == 3 || l == 4)	/* CPIO HEADER */
	    {
	      printf("cpio%d", (int)l);
	      stats_cpio++;
	      for (;;)
		{
		  int c = getc(fp);
		  if (c == EOF)
		    return;
		  stats_cpio_len++;
		  if (c == 0)
		    {
		      printf(" (0)");
		      break;
		    }
		  if (c < 128)
		    printf(" [%d]", c);
		  else if (c >= 252)
		    {
		      printf(" (%d)", c - 251);
		      break;
		    }
		  else
		    {
		      c -= 128;
		      printf(" %d", c);
		      stats_cpio_len += c;
		      while (c--)
		        if (getc(fp) == EOF)
			  return;
		    }
		}
	      printf("\n");
	    }
	  else if (l == 5 || l == 6 || l == 7)	/* ZERO */
	    {
	      printf("zero %d\n", (int)l - 4);
	      stats_zero++;
	      stats_zero_len += (int)l - 4;
	    }
	  else if (l == 15)				/* META */
	    {
	      l = expandobscpio_next(fp);
	      if (l == (unsigned long long)(-1))
		return;
	      if (l < 16 || l > sizeof(metabuf))
		return;
	      o = expandobscpio_next(fp);
	      if (o == (unsigned long long)(-1))
		return;
	      o = decodeoffset(oldoffset, o);
	      oldoffset = o + l;
	      printf("meta %#llx %llu\n", o, l);
	      stats_meta++;
	      stats_meta_len += l;
	      if (withmeta)
		{
		  oldoffset_meta = o + l;
		  oldoffset = 0;
		  if (pread(fdstore, metabuf, (size_t)l, (off_t)o) != (size_t)l)
		    return;
		  metal = (unsigned int)l;
		  meta = metabuf;
		}
	    }
	  else
	    return;
	  continue;
	}
      if (meta)
	printf("    ");
      if (l < 256)
	{
	  l -= 16;
	  printf("direct %d\n", (int)l);
	  if (meta)
	    {
	      stats_meta_direct++;
	      stats_meta_direct_len += l;
	    }
	  else
	    {
	      stats_direct++;
	      stats_direct_len += l;
	    }
	  if (meta)
	    {
	      if (l > metal)
		return;
	      metal -= l;
	      meta += l;
	    }
	  else
	    {
	      while (l--)
		if (getc(fp) == EOF)
		  return;
	    }
	  continue;
	}
      l -= 256;
      if (meta)
        o = expandobscpio_next_mem(&meta, &metal);
      else
        o = expandobscpio_next(fp);
      if (o == (unsigned long long)(-1))
	return;
      o = decodeoffset(oldoffset, o);
      oldoffset = o + l;
      printf("store %#llx %llu\n", o, l);
      if (meta)
	{
	  stats_meta_store++;
	  stats_meta_store_len += l;
	}
      else
	{
	  stats_store++;
	  stats_store_len += l;
	}
    }
  printf("stats cpio %u len %llu\n", stats_cpio, stats_cpio_len);
  printf("stats direct %u len %llu\n", stats_direct, stats_direct_len);
  if (withmeta)
    printf("stats meta_direct %u len %llu\n", stats_meta_direct, stats_meta_direct_len);
  printf("stats store %u len %llu\n", stats_store, stats_store_len);
  if (withmeta)
    printf("stats meta_store %u len %llu\n", stats_meta_store, stats_meta_store_len);
  printf("stats zero %u len %llu\n", stats_zero, stats_zero_len);
  printf("stats meta %u len %llu\n", stats_meta, stats_meta_len);
  if (withmeta)
    printf("stats instr %u\n", stats_cpio + stats_direct + stats_store + stats_zero + stats_meta + 1 + stats_meta_direct + stats_meta_store);
  printf("stats file_instr %u\n", stats_cpio + stats_direct + stats_store + stats_zero + stats_meta + 1);
  printf("stats file_data %lld\n", stats_cpio_len + stats_direct_len);
  printf("stats file_size %lld\n", (unsigned long long)ftell(fp));
}

MODULE = BSSolv		PACKAGE = BSSolv

void
depsort(HV *deps, SV *mapp, SV *cycp, ...)
    PPCODE:
	{
	    int i, j, k, cy, cycstart, nv;
	    SV *sv, **svp;
	    Id id, *e;
	    Id *mark;
	    char **names;
	    Hashtable ht;
	    Hashval h, hh, hm;
	    HV *mhv = 0;

	    Queue edata;
	    Queue vedge;
	    Queue todo;
	    Queue cycles;

	    if (items == 3)
	      XSRETURN_EMPTY; /* nothing to sort */
	    if (items == 4)
	      {
		/* only one item */
		char *s = SvPV_nolen(ST(3));
		EXTEND(SP, 1);
		sv = newSVpv(s, 0);
		PUSHs(sv_2mortal(sv));
	        XSRETURN(1); /* nothing to sort */
	      }

	    if (mapp && SvROK(mapp) && SvTYPE(SvRV(mapp)) == SVt_PVHV)
	      mhv = (HV *)SvRV(mapp);

	    queue_init(&edata);
	    queue_init(&vedge);
	    queue_init(&todo);
	    queue_init(&cycles);

	    hm = mkmask(items);
	    ht = solv_calloc(hm + 1, sizeof(*ht));
	    names = solv_calloc(items, sizeof(char *));
	    nv = 1;
	    for (i = 3; i < items; i++)
	      {
		char *s = SvPV_nolen(ST(i));
		h = strhash(s) & hm;
		hh = HASHCHAIN_START;
		while ((id = ht[h]) != 0)
		  {
		    if (!strcmp(names[id], s))
		      break;
		    h = HASHCHAIN_NEXT(h, hh, hm);
		  }
		if (id)
		  continue;	/* had that one before, ignore */
		id = nv++;
		ht[h] = id;
		names[id] = s;
	      }

	    /* we now know all vertices, create edges */
	    queue_push(&vedge, 0);
	    queue_push(&edata, 0);
	    for (i = 1; i < nv; i++)
	      {
		svp = hv_fetch(deps, names[i], strlen(names[i]), 0);
		sv = svp ? *svp : 0;
		queue_push(&vedge, edata.count);
		if (sv && SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVAV)
		  {
		    AV *av = (AV *)SvRV(sv);
		    for (j = 0; j <= av_len(av); j++)
		      {
			char *s;
			STRLEN slen;

			svp = av_fetch(av, j, 0);
			if (!svp)
			  continue;
			sv = *svp;
			s = SvPV(sv, slen);
			if (!s)
			  continue;
			if (mhv)
			  {
			    /* look up in dep map */
			    svp = hv_fetch(mhv, s, slen, 0);
			    if (svp)
			      {
				s = SvPV(*svp, slen);
				if (!s)
				  continue;
			      }
			  }
			/* look up in hash */
			h = strhash(s) & hm;
			hh = HASHCHAIN_START;
			while ((id = ht[h]) != 0)
			  {
			    if (!strcmp(names[id], s))
			      break;
			    h = HASHCHAIN_NEXT(h, hh, hm);
			  }
			if (!id)
			  continue;	/* not known, ignore */
			if (id == i)
			  continue;	/* no self edge */
			queue_push(&edata, id);
		      }
		  }
		queue_push(&edata, 0);
	      }
	    solv_free(ht);

	    if (0)
	      {
		printf("vertexes: %d\n", vedge.count - 1);
		for (i = 1; i < vedge.count; i++)
		  {
		    printf("%d %s:", i, names[i]);
		    Id *e = edata.elements + vedge.elements[i];
		    for (; *e; e++)
		      printf(" %d", *e);
		    printf("\n");
		  }
	      }
		

	    /* now everything is set up, sort em! */
	    mark = solv_calloc(vedge.count, sizeof(Id));
	    for (i = vedge.count - 1; i; i--)
	      queue_push(&todo, i);
	    EXTEND(SP, vedge.count - 1);
	    while (todo.count)
	      {
		i = queue_pop(&todo);
		// printf("check %d\n", i);
		if (i < 0)
		  {
		    i = -i;
		    mark[i] = 2;
		    sv = newSVpv(names[i], 0);
		    PUSHs(sv_2mortal(sv));
		    continue;
		  }
		if (mark[i] == 2)
		  continue;
		if (mark[i] == 0)
		  {
		    int edgestovisit = 0;
		    Id *e = edata.elements + vedge.elements[i];
		    for (; *e; e++)
		      {
			if (*e == -1)
			  continue;	/* broken */
			if (mark[*e] == 2)
			  continue;
			if (!edgestovisit++)
			  queue_push(&todo, -i);
		        queue_push(&todo, *e);
		      }
		    if (!edgestovisit)
		      {
			mark[i] = 2;
			sv = newSVpv(names[i], 0);
			PUSHs(sv_2mortal(sv));
		      }
		    else
		      mark[i] = 1;
		    continue;
		  }
		/* oh no, we found a cycle, record and break it */
		cy = cycles.count;
		for (j = todo.count - 1; j >= 0; j--)
		  if (todo.elements[j] == -i)
		    break;
		cycstart = j;
		// printf("cycle:\n");
		for (j = cycstart; j < todo.count; j++)
		  if (todo.elements[j] < 0)
		    {
		      k = -todo.elements[j];
		      mark[k] = 0;
		      queue_push(&cycles, k);
		      // printf("  %d\n", k);
		    }
	        queue_push(&cycles, 0);
		todo.elements[cycstart] = i;
		/* break it */
		for (k = cy; cycles.elements[k]; k++)
		  ;
		if (!cycles.elements[k])
		  k = cy;
		j = cycles.elements[k + 1] ? cycles.elements[k + 1] : cycles.elements[cy];
		k = cycles.elements[k];
		/* breaking edge from k -> j */
		// printf("break %d -> %d\n", k, j);
		e = edata.elements + vedge.elements[k];
		for (; *e; e++)
		  if (*e == j)
		    break;
		if (!*e)
		  abort();
		*e = -1;
		todo.count = cycstart + 1;
	      }

	    /* recored cycles */
	    if (cycles.count && cycp && SvROK(cycp) && SvTYPE(SvRV(cycp)) == SVt_PVAV)
	      {
		AV *av = (AV *)SvRV(cycp);
		for (i = 0; i < cycles.count;)
		  {
		    AV *av2 = newAV();
		    for (; cycles.elements[i]; i++)
		      {
			SV *sv = newSVpv(names[cycles.elements[i]], 0);
			av_push(av2, sv);
		      }
		    av_push(av, newRV_noinc((SV*)av2));
		    i++;
		  }
	      }
	    queue_free(&cycles);

	    queue_free(&edata);
	    queue_free(&vedge);
	    queue_free(&todo);
	    solv_free(mark);
	    solv_free(names);
	}

void
gen_meta(AV *subp, ...)
    PPCODE:
	{
	    Hashtable ht;
	    Hashval h, hh, hm;
	    char **subpacks;
	    struct metaline *lines, *lp;
	    int nlines;
	    int i, j, cycle, ns;
	    char *s, *s2, *lo;
	    Id id;
	    Queue cycles;
	    Id cycles_buf[64];

	    if (items == 1)
	      XSRETURN_EMPTY; /* nothing to generate */

	    queue_init_buffer(&cycles, cycles_buf, sizeof(cycles_buf)/sizeof(*cycles_buf));
	    hm = mkmask(av_len(subp) + 2);
	    ht = solv_calloc(hm + 1, sizeof(*ht));
	    subpacks = solv_calloc(av_len(subp) + 2, sizeof(char *));
	    for (j = 0; j <= av_len(subp); j++)
	      {
		SV **svp = av_fetch(subp, j, 0);
		if (!svp)
		  continue;
		s = SvPV_nolen(*svp);
		h = strhash(s) & hm;
		hh = HASHCHAIN_START;
		while ((id = ht[h]) != 0)
		  h = HASHCHAIN_NEXT(h, hh, hm);
		ht[h] = j + 1;
		subpacks[j + 1] = s;
	      }

	    lines = solv_calloc(items - 1, sizeof(*lines));
	    nlines = items - 1;
	    /* lines are of the form "md5sum  pkg/pkg..." */
	    for (i = 0, lp = lines; i < nlines; i++, lp++)
	      {
		s = SvPV_nolen(ST(i + 1));
		if (strlen(s) < 35 || s[32] != ' ' || s[33] != ' ')
		  croak("gen_meta: bad line %s\n", s);
		/* count '/' */
		lp->l = s;
		ns = 0;
		cycle = 0;
		lo = s + 34;
		for (s2 = lo; *s2; s2++)
		  if (*s2 == '/')
		    {
		      if (!cycle)	
			{
			  *s2 = 0;
			  h = strhash(lo) & hm;
			  hh = HASHCHAIN_START;
			  while ((id = ht[h]) != 0)
			    {
			      if (!strcmp(lo, subpacks[id]))
				break;
			      h = HASHCHAIN_NEXT(h, hh, hm);
			    }
			  *s2 = '/';
			  if (id)
			    cycle = 1 + ns;
			}
		      ns++;
		      lo = s2 + 1;
		    }
		if (!cycle)
		  {
		    h = strhash(lo) & hm;
		    hh = HASHCHAIN_START;
		    while ((id = ht[h]) != 0)
		      {
		        if (!strcmp(lo, subpacks[id]))
			  break;
		        h = HASHCHAIN_NEXT(h, hh, hm);
		      }
		    if (id)
		      cycle = 1 + ns;
		  }
		if (cycle)
		  {
		    lp->killed = 1;
		    if (cycle > 1)	/* ignore self cycles */
		      queue_push(&cycles, i);
		  }
		lp->nslash = ns;
		lp->lastoff = lo - s;
	      }
	    solv_free(ht);
	    solv_free(subpacks);

	    /* if we found cycles, prune em */
	    if (cycles.count)
	      {
		char *cycledata = 0;
		int cycledatalen = 0;

		cycledata = solv_extend(cycledata, cycledatalen, 1, 1, 255);
		cycledata[0] = 0;
		cycledatalen += 1;
		hm = mkmask(cycles.count);
		ht = solv_calloc(hm + 1, sizeof(*ht));
		for (i = 0; i < cycles.count; i++)
		  {
		    char *se;
		    s = lines[cycles.elements[i]].l + 34;
		    se = strchr(s, '/');
		    if (se)
		      *se = 0;
		    h = strhash(s) & hm;
		    hh = HASHCHAIN_START;
		    while ((id = ht[h]) != 0)
		      {
		        if (!strcmp(s, cycledata + id))
			  break;
		        h = HASHCHAIN_NEXT(h, hh, hm);
		      }
		    if (id)
		      continue;
		    cycledata = solv_extend(cycledata, cycledatalen, strlen(s) + 1, 1, 255);
		    ht[h] = cycledatalen;
		    strcpy(cycledata + cycledatalen, s);
		    cycledatalen += strlen(s) + 1;
		    if (se)
		      *se = '/';
		  }
		for (i = 0, lp = lines; i < nlines; i++, lp++)
		  {
		    if (lp->killed || !lp->nslash)
		      continue;
		    lo = strchr(lp->l + 34, '/') + 1;
		    for (s2 = lo; *s2; s2++)
		      if (*s2 == '/')
			{
			  *s2 = 0;
			  h = strhash(lo) & hm;
			  hh = HASHCHAIN_START;
			  while ((id = ht[h]) != 0)
			    {
			      if (!strcmp(lo, cycledata + id))
				break;
			      h = HASHCHAIN_NEXT(h, hh, hm);
			    }
			  *s2 = '/';
			  if (id)
			    {
			      lp->killed = 1;
			      break;
			    }
			  lo = s2 + 1;
			}
		    if (lp->killed)
		      continue;
		    h = strhash(lo) & hm;
		    hh = HASHCHAIN_START;
		    while ((id = ht[h]) != 0)
		      {
		        if (!strcmp(lo, cycledata + id))
			  break;
		        h = HASHCHAIN_NEXT(h, hh, hm);
		      }
		    if (id)
		      {
		        lp->killed = 1;
		      }
		  }
		solv_free(ht);
		cycledata = solv_free(cycledata);
		queue_free(&cycles);
	      }

	    /* cycles are pruned, now sort array */
	    if (nlines > 1)
	      qsort(lines, nlines, sizeof(*lines), metacmp);

	    hm = mkmask(nlines);
	    ht = solv_calloc(hm + 1, sizeof(*ht));
	    for (i = 0, lp = lines; i < nlines; i++, lp++)
	      {
		if (lp->killed)
		  continue;
		s = lp->l;
		h = strnhash(s, 10);
		h = strhash_cont(s + lp->lastoff, h) & hm;
	        hh = HASHCHAIN_START;
		while ((id = ht[h]) != 0)
		  {
		    struct metaline *lp2 = lines + (id - 1);
		    if (!strncmp(lp->l, lp2->l, 32) && !strcmp(lp->l + lp->lastoff, lp2->l + lp2->lastoff))
		      break;
		    h = HASHCHAIN_NEXT(h, hh, hm);
		  }
		if (id)
		  lp->killed = 1;
		else
		  ht[h] = i + 1;
	      }
	    solv_free(ht);
	    j = 0;
	    for (i = 0, lp = lines; i < nlines; i++, lp++)
	      if (!lp->killed)
		j++;
	    EXTEND(SP, j);
	    for (i = 0, lp = lines; i < nlines; i++, lp++)
	      {
		SV *sv;
		if (lp->killed)
		  continue;
		sv = newSVpv(lp->l, 0);
		PUSHs(sv_2mortal(sv));
	      }
	    solv_free(lines);
	}

void
add_meta(AV *new_meta, SV *sv, const char *bin, const char *packid = 0)
    PPCODE:
	{
	    const char *p, *np;
	    char *buf;
	    size_t l, bufl, binl, packidl;
	    int first = 1;
	    if (SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVAV) {
		AV *av = (AV *)SvRV(sv);
		SV **svp = av_fetch(av, 0, 0);
		sv = svp ? *svp : 0;
	    }
	    if (!sv)
		XSRETURN_EMPTY;
	    p = SvPV_nolen(sv);
	    binl = strlen(bin);
	    bufl = binl + 256;
	    buf = malloc(bufl);
	    if (!buf) {
		croak("out of mem\n");
		XSRETURN_EMPTY;
	    }
	    packidl = packid ? strlen(packid) : 0;
	    for (;;) {
		np = strchr(p, '\n');
		l = np ? np - p : strlen(p);
		if (l > 34) {
		    if (l + binl + 1 + 1 > bufl) {
			bufl = l + binl + 256;
			buf = realloc(buf, bufl);
			if (!buf) {
			    croak("out of mem\n");
			    XSRETURN_EMPTY;
			}
		    }
		    strncpy(buf, p, 34);
		    strcpy(buf + 34, bin);
		    buf[34 + binl] = '/';
		    strncpy(buf + 34 + binl + 1, p + 34, l - 34);
		    l += binl + 1;
		    buf[l] = 0;
		    if (first) {
			if (packidl && l > packidl + 1 && buf[l - packidl - 1] == '/' && !strcmp(buf + l - packidl, packid)) {
			    free(buf);
			    XSRETURN_EMPTY;
			}
			l = 34 + binl;
			buf[l] = 0;
			first = 0;
		    }
		    av_push(new_meta, newSVpvn(buf, l));
		}
		if (!np)
		    break;
		p = np + 1;
	    }
	    free(buf);
	}

SV *
thawcache(SV *sv)
    CODE:
	unsigned char *src;
	STRLEN srcl;
	if (!SvPOK(sv)) {
	    croak("thaw: argument is not a string\n");
	    XSRETURN_UNDEF;
	}
	src = (unsigned char *)SvPV(sv, srcl);
	if (srcl < 7 || src[0] != 'p' || src[1] != 's' || src[2] != 't' || src[3] != '0') {
	    croak("thaw: argument is not a perl storable\n");
	    XSRETURN_UNDEF;
	}
	if ((src[4] & 1) != 1) {
	    croak("thaw: argument is not a perl storable in network order\n");
	    XSRETURN_UNDEF;
	}
	if (src[4] < 5) {
	    croak("thaw: argument is a perl storable with a too old version\n");
	    XSRETURN_UNDEF;
	}
        src += 6;
        srcl -= 6;
	sv = retrieve(&src, &srcl, 0);
	if (sv == 0 || srcl) {
	    croak("thaw: corrupt storable\n");
	    XSRETURN_UNDEF;
	}
	RETVAL = newRV_noinc(sv);
    OUTPUT:
	RETVAL

int
isobscpio(const char *file)
    CODE:
	int fd;
	RETVAL = 0;
	if ((fd = open(file, O_RDONLY)) != -1) {
	    unsigned char magic[16];
	    if (read(fd, magic, 16) == 16 && !memcmp(magic, "OBScpio", 7))
		RETVAL = 1;
	    close(fd);
	}
    OUTPUT:
	RETVAL


void
obscpiostat(const char *file)
    PPCODE:
	{
	    int fd;
	    struct stat st;
	    if ((fd = open(file, O_RDONLY)) != -1) {
		if (!fstat(fd, &st)) {
		    unsigned char magic[16];
		    if (read(fd, magic, 16) == 16 && !memcmp(magic, "OBScpio", 7)) {
			st.st_size = getu48(magic + 10);
		    }
		    EXTEND(SP, 10);
		    PUSHs(&PL_sv_undef);
		    PUSHs(&PL_sv_undef);
		    PUSHs(sv_2mortal(newSVuv((UV)st.st_mode)));
		    PUSHs(sv_2mortal(newSVuv((UV)st.st_nlink)));
		    PUSHs(&PL_sv_undef);
		    PUSHs(&PL_sv_undef);
		    PUSHs(&PL_sv_undef);
#if IVSIZE > 4
		    PUSHs(sv_2mortal(newSVuv((UV)st.st_size)));
#else
		    PUSHs(sv_2mortal(newSVnv((double)st.st_size)));
#endif
		    PUSHs(sv_2mortal(newSVuv((UV)st.st_atime)));
		    PUSHs(sv_2mortal(newSVuv((UV)st.st_mtime)));
		    PUSHs(sv_2mortal(newSVuv((UV)st.st_ctime)));
		}
		close(fd);
	    }
	}

int
obscpioopen(const char *file, const char *store, SV *gvrv, const char *tmpdir = 0)
    CODE:
	int fd;
	GV *gv;
	if (!SvROK(gvrv) || SvTYPE(SvRV(gvrv)) != SVt_PVGV) {
	    croak("obscpioopen needs a GV reference\n");
	}
	if (tmpdir && strlen(tmpdir) > 200) {
	    croak("tmpdir too long\n");
	}
	gv = (GV *)SvRV(gvrv);
	RETVAL = 0;
	if ((fd = open(file, O_RDONLY)) != -1) {
	    unsigned char magic[16];
	    if (read(fd, magic, 16) == 16 && !memcmp(magic, "OBScpio", 7)) {
		char template[256];
		int nfd = -1;
		int sfd;
		if ((sfd = open(store, O_RDONLY)) != -1) {
		    if (tmpdir) {
			strcpy(template, tmpdir);
			strcat(template, "/obscpioopen-XXXXXX");
		    } else {
			strcpy(template, "/var/tmp/obscpioopen-XXXXXX");
		    }
		    nfd = mkstemp(template);
		    if (nfd != -1) {
			FILE *fp = 0, *nfp = 0;
		        unlink(template);
			lseek(fd, 0, SEEK_SET);
			if ((fp = fdopen(fd, "r")) == 0)
			    close(fd);
			if ((nfp = fdopen(nfd, "w+")) == 0)
			    close(nfd);
		        if (fp && nfp && expandobscpio(fp, sfd, nfp)) {
			    nfd = dup(nfd);
			    if (fclose(nfp)) {
				close(nfd);
			        nfd = -1;
			    }
			    nfp = 0;
			} else {
			    nfd = -1;
			}
			if (fp)
			    fclose(fp);
			if (nfp)
			    fclose(nfp);
			fd = -1;
		    }
		    close(sfd);
		}
		if (fd != -1)
		    close(fd);
		fd = nfd;
	    }
	    if (fd != -1) {
		IO * io = GvIOn(gv);
		PerlIO *fp;

		lseek(fd, 0, SEEK_SET);
		fp = PerlIO_fdopen(fd, "rb");
		if (fp) {
		    IoIFP(io) = fp;
		    RETVAL = 1;
		}
	    }
	}
	
    OUTPUT:
	RETVAL

int
expandobscpio(const char *file, const char *store, const char *tmpfile)
    CODE:
	{
	    int fd, nfd, sfd;
	    RETVAL = 0;

	    unlink(tmpfile);
	    if ((fd = open(file, O_RDONLY)) != -1) {
		unsigned char magic[16];
		if (!(read(fd, magic, 16) == 16 && !memcmp(magic, "OBScpio", 7))) {
		    close(fd);
		    fd = -1;
		    if (link(file, tmpfile) == 0 && (fd = open(tmpfile, O_RDONLY)) != -1) {
			if (read(fd, magic, 16) == 16 && !memcmp(magic, "OBScpio", 7)) {
			    unlink(tmpfile);
			} else {
			    close(fd);
			    fd = -1;
			    RETVAL = 1;
			}
		    }
		}
		if (fd != -1) {
		    if ((sfd = open(store, O_RDONLY)) != -1) {
			FILE *fp;
			lseek(fd, 0, SEEK_SET);
			if ((fp = fdopen(fd, "r")) == 0)
			    close(fd);
			if (fp && (nfd = open(tmpfile, O_WRONLY|O_CREAT|O_TRUNC|O_EXCL, 0666)) != -1) {
			    FILE *nfp;
			    if ((nfp = fdopen(nfd, "w")) == 0)
				close(nfd);
			    if (nfp && expandobscpio(fp, sfd, nfp)) {
				if (!fclose(nfp))
				    RETVAL = 1;
				else
				    unlink(tmpfile);
				nfp = 0;
			    } else
				unlink(tmpfile);
			    if (nfp)
				fclose(nfp);
			}
		        if (fp)
			  fclose(fp);
			close(sfd);
		    } else {
		      close(fd);
		    }
		}
	    }
	}
    OUTPUT:
	RETVAL


int
makeobscpio(const char *in, const char *store, const char *out)
    CODE:
	{
	    FILE *fpin, *fpout;
	    struct stat st;
	    int fdstore;
	    RETVAL = 0;
	    if ((fpin = fopen(in, "r")) == 0) {	
		perror(in);
	    } else if (fstat(fileno(fpin), &st) != 0) {
		perror(in);
	        fclose(fpin);
	    } else if ((fpout = fopen(out, "w")) == 0) {
	        perror(out);
	        fclose(fpin);
	    } else if ((fdstore = open(store, O_RDWR|O_CREAT, 0666)) == -1) {
	        perror(store);
	        fclose(fpin);
	        fclose(fpout);
	    } else {
		int gotlock = 0;
	        while (!gotlock) {
		    if (flock(fdstore, LOCK_EX) == 0)
			gotlock = 1;
		    else if (errno != EINTR)
			break;
		}
		if (gotlock) {
		    struct deltastore store;
		    if (readdeltastore(&store, fdstore, 0, (unsigned long long)st.st_size)) {
			int r = makedelta(&store, fpin, fpout, (unsigned long long)st.st_size);
#if 0
  printf("after makedelta: have %d entries, hash size %d\n", store.hf, store.hm + 1);
#endif
			if (fsync(store.fd))
			  r = 0;
			freedeltastore(&store);
			if (r) {
			    settimes(fileno(fpout), &st);
			    RETVAL = 1;
			}
		    }
		}
		close(fdstore);
	        fclose(fpin);
	        fclose(fpout);
	    }
	}
    OUTPUT:
	RETVAL

void
obscpiostorestats(const char *store)
    CODE:
	{
	    int fdstore;

	    if ((fdstore = open(store, O_RDONLY)) == -1)
	        perror(store);
	    else {
		int gotlock = 0;
		while (!gotlock) {
		    if (flock(fdstore, LOCK_EX) == 0)
			gotlock = 1;
		    else if (errno != EINTR)
			break;
		}
		if (gotlock) {
		    struct deltastore store;
		    if (readdeltastore(&store, fdstore, 1, (unsigned long long)0)) {
			printdeltastorestats(&store);
			fsync(store.fd);
			freedeltastore(&store);
		    }
		}
		close(fdstore);
	    }
	}

void
obscpioinstr(const char *file, const char *store = 0)
    CODE:
	{
	    FILE *fp;
	    int fdstore = -1;
	    if ((fp = fopen(file, "r")) == 0)
		perror(file);
	    else {
		if (store) {
		    fdstore = open(store, O_RDONLY);
		    if (fdstore == -1)
			perror(store);
		}
		printobscpioinstr(fp, fdstore, fdstore == -1 ? 0 : 1);
		fclose(fp);
		if (fdstore != -1)
		    close(fdstore);
	    }
	}


MODULE = BSSolv		PACKAGE = BSSolv::pool		PREFIX = pool

PROTOTYPES: ENABLE

BSSolv::pool
new(char *packname = "BSSolv::pool")
    CODE:
	{
	    Pool *pool = pool_create();
	    set_disttype(pool, DISTTYPE_RPM);
	    buildservice_id = pool_str2id(pool, "buildservice:id", 1);
	    buildservice_repocookie= pool_str2id(pool, "buildservice:repocookie", 1);
	    buildservice_external = pool_str2id(pool, "buildservice:external", 1);
	    buildservice_dodurl = pool_str2id(pool, "buildservice:dodurl", 1);
	    expander_directdepsend = pool_str2id(pool, "-directdepsend--", 1);
	    buildservice_dodcookie = pool_str2id(pool, "buildservice:dodcookie", 1);
	    pool_freeidhashes(pool);
	    RETVAL = pool;
	}
    OUTPUT:
	RETVAL

void
settype(BSSolv::pool pool, char *type)
    CODE:
	if (!strcmp(type, "rpm"))
	  set_disttype(pool, DISTTYPE_RPM);
#ifdef DISTTYPE_DEB
	else if (!strcmp(type, "deb"))
	  set_disttype(pool, DISTTYPE_DEB);
#endif
#ifdef DISTTYPE_ARCH
	else if (!strcmp(type, "arch"))
	  set_disttype(pool, DISTTYPE_ARCH);
#endif
	else
	  croak("settype: unknown type '%s'\n", type);


BSSolv::repo
repofromfile(BSSolv::pool pool, char *name, char *filename)
    CODE:
	FILE *fp;
	fp = fopen(filename, "r");
	if (!fp) {
	    croak("%s: %s\n", filename, Strerror(errno));
	    XSRETURN_UNDEF;
	}
	RETVAL = repo_create(pool, name);
	repo_add_solv(RETVAL, fp, 0);
	fclose(fp);
    OUTPUT:
	RETVAL

BSSolv::repo
repofromstr(BSSolv::pool pool, char *name, SV *sv)
    CODE:
	FILE *fp;
	STRLEN len;
	char *buf;
	buf = SvPV(sv, len);
	if (!buf)
	    croak("repofromstr: undef string\n");
	fp = fmemopen(buf, len, "r");
	if (!fp) {
	    croak("fmemopen failed\n");
	    XSRETURN_UNDEF;
	}
	RETVAL = repo_create(pool, name);
	repo_add_solv(RETVAL, fp, 0);
	fclose(fp);
    OUTPUT:
	RETVAL

BSSolv::repo
repofrombins(BSSolv::pool pool, char *name, char *dir, ...)
    CODE:
	{
	    int i;
	    Repo *repo;
	    Repodata *data;
	    repo = repo_create(pool, name);
	    data = repo_add_repodata(repo, 0);
	    for (i = 3; i + 1 < items; i += 2)
	      {
		STRLEN sl;
		char *s = SvPV(ST(i), sl);
		char *sid = SvPV_nolen(ST(i + 1));
		if (sl < 4)
		  continue;
		if (strcmp(s + sl - 4, ".rpm")
                    && strcmp(s + sl - 4, ".deb")
#ifdef ARCH_ADD_WITH_PKGID
                    && (sl < 11 || strcmp(s + sl - 11, ".pkg.tar.gz"))
                    && (sl < 11 || strcmp(s + sl - 11, ".pkg.tar.xz"))
#endif
		   )
		  continue;
		if (sl >= 10 && !strcmp(s + sl - 10, ".patch.rpm"))
		  continue;
		if (sl >= 10 && !strcmp(s + sl - 10, ".nosrc.rpm"))
		  continue;
		if (sl >= 8 && !strcmp(s + sl - 8, ".src.rpm"))
		  continue;
		repodata_addbin(data, dir, s, (int)sl, sid);
	      }
	    repo_set_str(repo, SOLVID_META, buildservice_repocookie, REPOCOOKIE);
	    repo_internalize(repo);
	    RETVAL = repo;
	}
    OUTPUT:
	RETVAL

BSSolv::repo
repofromdata(BSSolv::pool pool, char *name, HV *rhv)
    CODE:
	{
	    Repo *repo;
	    Repodata *data;
	    repo = repo_create(pool, name);
	    data = repo_add_repodata(repo, 0);
	    data2solvables(repo, data, rhv);
	    if (name && !strcmp(name, "/external/"))
	      repodata_set_void(data, SOLVID_META, buildservice_external);
	    repo_internalize(repo);
	    RETVAL = repo;
	}
    OUTPUT:
	RETVAL

void
createwhatprovides(BSSolv::pool pool)
    CODE:
	if (pool->considered)
	  {
	    map_free(pool->considered);
	    solv_free(pool->considered);
	  }
	pool->considered = solv_calloc(sizeof(Map), 1);
	create_considered(pool, 0, pool->considered);
	pool_createwhatprovides(pool);

void
setdebuglevel(BSSolv::pool pool, int level)
    CODE:
	pool_setdebuglevel(pool, level);

void
whatprovides(BSSolv::pool pool, char *str)
    PPCODE:
	{
	    Id p, pp, id;
	    id = dep2id(pool, str);
	    if (id)
	      FOR_PROVIDES(p, pp, id)
		XPUSHs(sv_2mortal(newSViv((IV)p)));
	}

void
whatrequires(BSSolv::pool pool, char *str)
    PPCODE:
	{
	    Id p, id;
	    Id *pp;
	    Solvable *s;
	    id = dep2id(pool, str);
	    if (id)
	      {
		for (p = 2; p < pool->nsolvables; p++)
		  {
		    if (!MAPTST(pool->considered, p))
		      continue;
		    s = pool->solvables + p;
		    if (!s->requires)
		      continue;
		    for (pp = s->repo->idarraydata + s->requires; *pp; pp++)
		      if (pool_match_dep(pool, id, *pp))
			break;
		    if (*pp)
		      XPUSHs(sv_2mortal(newSViv((IV)p)));
		  }
	      }
	}

void
consideredpackages(BSSolv::pool pool)
    PPCODE:
	{
	    int p, nsolv = 0;
	    for (p = 2; p < pool->nsolvables; p++)
	      if (MAPTST(pool->considered, p))
		nsolv++;
	    EXTEND(SP, nsolv);
	    for (p = 2; p < pool->nsolvables; p++)
	      if (MAPTST(pool->considered, p))
		PUSHs(sv_2mortal(newSViv((IV)p)));
	}
	
void
allpackages(BSSolv::pool pool)
    PPCODE:
	{
	    int p, nsolv = 0;
	    for (p = 2; p < pool->nsolvables; p++)
	      if (pool->solvables[p].repo)
		nsolv++;
	    EXTEND(SP, nsolv);
	    for (p = 2; p < pool->nsolvables; p++)
	      if (pool->solvables[p].repo)
		PUSHs(sv_2mortal(newSViv((IV)p)));
	}

const char *
pkg2name(BSSolv::pool pool, int p)
    CODE:
	RETVAL = pool_id2str(pool, pool->solvables[p].name);
    OUTPUT:
	RETVAL

const char *
pkg2srcname(BSSolv::pool pool, int p)
    CODE:
	if (solvable_lookup_void(pool->solvables + p, SOLVABLE_SOURCENAME))
	  RETVAL = pool_id2str(pool, pool->solvables[p].name);
	else
	  RETVAL = solvable_lookup_str(pool->solvables + p, SOLVABLE_SOURCENAME);
    OUTPUT:
	RETVAL

const char *
pkg2pkgid(BSSolv::pool pool, int p)
    CODE:
	{
	    Id type;
	    const char *s = solvable_lookup_checksum(pool->solvables + p, SOLVABLE_PKGID, &type);
	    RETVAL = s;
	}
    OUTPUT:
	RETVAL

const char *
pkg2bsid(BSSolv::pool pool, int p)
    CODE:
	RETVAL = solvable_lookup_str(pool->solvables + p, buildservice_id);
    OUTPUT:
	RETVAL

const char *
pkg2reponame(BSSolv::pool pool, int p)
    CODE:
	{
	    Repo *repo = pool->solvables[p].repo;
	    RETVAL = repo ? repo->name : 0;
	}
    OUTPUT:
	RETVAL

const char *
pkg2path(BSSolv::pool pool, int p)
    CODE:
	{
	    unsigned int medianr;
	    RETVAL = solvable_get_location(pool->solvables + p, &medianr);
	}
    OUTPUT:
	RETVAL
	
const char *
pkg2fullpath(BSSolv::pool pool, int p, char *myarch)
    CODE:
	{
	    unsigned int medianr;
	    const char *s = solvable_get_location(pool->solvables + p, &medianr);
	    Repo *repo = pool->solvables[p].repo;
	    s = pool_tmpjoin(pool, myarch, "/:full/", s);
	    RETVAL = pool_tmpjoin(pool, repo->name, "/", s);
	}
    OUTPUT:
	RETVAL

int
pkg2sizek(BSSolv::pool pool, int p)
    CODE:
#ifdef SOLV_KV_NUM64
	RETVAL = solvable_lookup_sizek(pool->solvables + p, SOLVABLE_DOWNLOADSIZE, 0);
#else
	RETVAL = solvable_lookup_num(pool->solvables + p, SOLVABLE_DOWNLOADSIZE, 0);
#endif
    OUTPUT:
	RETVAL

const char *
pkg2checksum(BSSolv::pool pool, int p)
    CODE:
	{
	    Id type;
	    const char *s = solvable_lookup_checksum(pool->solvables + p, SOLVABLE_CHECKSUM, &type);
	    if (s)
		s = pool_tmpjoin(pool, solv_chksum_type2str(type), ":", s);
	    RETVAL = s;
	}
    OUTPUT:
	RETVAL

int
verifypkgchecksum(BSSolv::pool pool, int p, char *path)
    CODE:
	{
	    Id type;
	    const unsigned char *cin, *cout;
	    FILE *fp;
	    void *cs;
	    int cslen;
	    char buf[4096];
	    size_t len;
	    int res = 0;

	    if ((cin = solvable_lookup_bin_checksum(pool->solvables + p, SOLVABLE_CHECKSUM, &type)) != 0) {
		if ((fp = fopen(path, "r")) != 0) {
		    if ((cs = solv_chksum_create(type)) != 0) {
			while ((len = fread(buf, 1, sizeof(buf), fp)) > 0)
			    solv_chksum_add(cs, buf, len);
			if ((cout = solv_chksum_get(cs, &cslen)) != 0 && cslen && !memcmp(cin, cout, cslen))
			    res = 1;
			solv_chksum_free(cs, 0);
		    }
		    fclose(fp);
		}
	    }
	    RETVAL = res;
	}
    OUTPUT:
	RETVAL

HV *
pkg2data(BSSolv::pool pool, int p)
    CODE:
	{
	    Solvable *s = pool->solvables + p;
	    Id id;
	    const char *ss, *se;
	    unsigned int medianr;

	    if (!s->repo)
		XSRETURN_EMPTY;
	    RETVAL = newHV();
	    sv_2mortal((SV*)RETVAL);
	    (void)hv_store(RETVAL, "name", 4, newSVpv(pool_id2str(pool, s->name), 0), 0);
	    ss = pool_id2str(pool, s->evr);
	    se = ss;
	    while (*se >= '0' && *se <= '9')
	      se++;
	    if (se != ss && *se == ':' && se[1])
	      {
		(void)hv_store(RETVAL, "epoch", 5, newSVpvn(ss, se - ss), 0);
		ss = se + 1;
	      }
	    se = strrchr(ss, '-');
	    if (se)
	      {
	        (void)hv_store(RETVAL, "version", 7, newSVpvn(ss, se - ss), 0);
	        (void)hv_store(RETVAL, "release", 7, newSVpv(se + 1, 0), 0);
	      }
	    else
	      (void)hv_store(RETVAL, "version", 7, newSVpv(ss, 0), 0);
	    (void)hv_store(RETVAL, "arch", 4, newSVpv(pool_id2str(pool, s->arch), 0), 0);
	    exportdeps(RETVAL, "provides", 8, s->repo, s->provides, SOLVABLE_PROVIDES);
	    exportdeps(RETVAL, "obsoletes", 9, s->repo, s->obsoletes, SOLVABLE_OBSOLETES);
	    exportdeps(RETVAL, "conflicts", 9, s->repo, s->conflicts, SOLVABLE_CONFLICTS);
	    exportdeps(RETVAL, "requires", 8, s->repo, s->requires, SOLVABLE_REQUIRES);
	    exportdeps(RETVAL, "recommends", 10, s->repo, s->recommends, SOLVABLE_RECOMMENDS);
	    exportdeps(RETVAL, "suggests", 8, s->repo, s->suggests, SOLVABLE_SUGGESTS);
	    exportdeps(RETVAL, "supplements", 11, s->repo, s->supplements, SOLVABLE_SUPPLEMENTS);
	    exportdeps(RETVAL, "enhances", 8, s->repo, s->enhances, SOLVABLE_ENHANCES);
	    if (solvable_lookup_void(s, SOLVABLE_SOURCENAME))
	      ss = pool_id2str(pool, s->name);
	    else
	      ss = solvable_lookup_str(s, SOLVABLE_SOURCENAME);
	    if (ss)
	      (void)hv_store(RETVAL, "source", 6, newSVpv(ss, 0), 0);
	    ss = solvable_get_location(s, &medianr);
	    if (ss)
	      (void)hv_store(RETVAL, "path", 4, newSVpv(ss, 0), 0);
	    ss = solvable_lookup_checksum(s, SOLVABLE_PKGID, &id);
	    if (ss && id == REPOKEY_TYPE_MD5)
	      (void)hv_store(RETVAL, "hdrmd5", 6, newSVpv(ss, 0), 0);
	    ss = solvable_lookup_str(s, buildservice_id);
	    if (ss)
	      (void)hv_store(RETVAL, "id", 2, newSVpv(ss, 0), 0);
	}
    OUTPUT:
	RETVAL

void
repos(BSSolv::pool pool)
    PPCODE:
	{
	    int ridx;
	    Repo *repo;

	    EXTEND(SP, pool->nrepos);
	    FOR_REPOS(ridx, repo)
	      {
		SV *sv = sv_newmortal();
		sv_setref_pv(sv, "BSSolv::repo", (void *)repo);
		PUSHs(sv);
	      }
	}

void
preparehashes(BSSolv::pool pool, char *prp, SV *gctxprpnotreadysv = 0)
    PPCODE:
	{
	    HV *gctxprpnotready = 0;
	    int ridx;
	    Repo *repo;
	    /* generated: */
	    HV *depislocal = newHV();
	    HV *dep2pkg = newHV();
	    HV *dep2src = newHV();
	    HV *notready = newHV();
	    HV *subpacks = newHV();
	    const char *srcstr;
	    const char *str;
	    Queue subq;
	    Id lastsrc, srcname, srctype;
	    int i, j;
	    Id p;
	    Solvable *s;
	    SV *sv, **svp;

	    if (gctxprpnotreadysv && SvROK(gctxprpnotreadysv) && SvTYPE(SvRV(gctxprpnotreadysv)) == SVt_PVHV)
	      gctxprpnotready = (HV *)SvRV(gctxprpnotreadysv);
	    queue_init(&subq);
	    FOR_REPOS(ridx, repo)
	      {
		HV *prpnotready = 0;
		int islocal = repo->name && !strcmp(repo->name, prp);
		svp = 0;
		if (repo->name && !islocal && gctxprpnotready)
		  svp = hv_fetch(gctxprpnotready, repo->name, strlen(repo->name), 0);
		if (svp && *svp && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVHV)
		  prpnotready = (HV *)SvRV(*svp);
		FOR_REPO_SOLVABLES(repo, p, s)
		  {
		    if (!MAPTST(pool->considered, p))
		      continue;
		    srctype = solvable_lookup_type(pool->solvables + p, SOLVABLE_SOURCENAME);
		    if (srctype == REPOKEY_TYPE_VOID)
		      srcname = s->name;
		    else if (srctype == REPOKEY_TYPE_ID)
		      srcname = solvable_lookup_id(pool->solvables + p, SOLVABLE_SOURCENAME);
		    else
		      {
			srcstr = solvable_lookup_str(pool->solvables + p, SOLVABLE_SOURCENAME);
			srcname = srcstr ? pool_str2id(pool, srcstr, 1) : 0;
		      }
		    if (!srcname || srcname == 1)
		      srcname = s->name;
		    queue_push2(&subq, s->name, srcname);

		    str = pool_id2str(pool, s->name);
		    (void)hv_store(dep2pkg, str, strlen(str), newSViv((IV)p), 0);
		    if (islocal)
		      (void)hv_store(depislocal, str, strlen(str), newSViv((IV)1), 0);
		    srcstr = pool_id2str(pool, srcname);
		    (void)hv_store(dep2src, str, strlen(str), newSVpv(srcstr, 0), 0);
		    if (!islocal && prpnotready)
		      {
			svp = hv_fetch(prpnotready, srcstr, strlen(srcstr), 0);
			if (svp && *svp && SvTRUE(*svp))
			  (void)hv_store(notready, srcstr, strlen((char *)srcstr), newSViv((IV)2), 0);
		      }
		  }
	      }
	    solv_sort(subq.elements, subq.count / 2, sizeof(Id) * 2, subpack_sort_cmp, pool);
	    queue_push2(&subq, 0, 0);
	    lastsrc = 0;
	    for (i = j = 0; i < subq.count; i += 2)
	      {
		if (subq.elements[i + 1] != lastsrc)
		  {
		    if (j < i)
		      {
			AV *subs = newAV();
			for (; j < i; j += 2)
			  {
			    str = pool_id2str(pool,  subq.elements[j]);
			    av_push(subs, newSVpv(str, 0));
			  }
			str = pool_id2str(pool, lastsrc);
		        (void)hv_store(subpacks, str, strlen(str), newRV_noinc((SV *)subs), 0);
		      }
		    lastsrc = subq.elements[i + 1];
		  }
	      }
	    queue_free(&subq);
	    EXTEND(SP, 5);
	    sv = newRV_noinc((SV *)dep2pkg);
	    PUSHs(sv_2mortal(sv));
	    sv = newRV_noinc((SV *)dep2src);
	    PUSHs(sv_2mortal(sv));
	    sv = newRV_noinc((SV *)depislocal);
	    PUSHs(sv_2mortal(sv));
	    sv = newRV_noinc((SV *)notready);
	    PUSHs(sv_2mortal(sv));
	    sv = newRV_noinc((SV *)subpacks);
	    PUSHs(sv_2mortal(sv));
	}

void
DESTROY(BSSolv::pool pool)
    CODE:
        if (pool->considered)
	  {
	    map_free(pool->considered);
	    pool->considered = solv_free(pool->considered);
	  }
	pool_free(pool);




MODULE = BSSolv		PACKAGE = BSSolv::repo		PREFIX = repo

void
pkgnames(BSSolv::repo repo)
    PPCODE:
	{
	    Pool *pool = repo->pool;
	    Id p;
	    Solvable *s;
	    Map c;
	
	    create_considered(pool, repo, &c);
	    EXTEND(SP, 2 * repo->nsolvables);
	    FOR_REPO_SOLVABLES(repo, p, s)
	      {
		if (!MAPTST(&c, p))
		  continue;
		PUSHs(sv_2mortal(newSVpv(pool_id2str(pool, s->name), 0)));
		PUSHs(sv_2mortal(newSViv(p)));
	      }
	    map_free(&c);
	}

void
pkgpaths(BSSolv::repo repo)
    PPCODE:
	{
	    Pool *pool = repo->pool;
	    Id p;
	    Solvable *s;
	    Map c;
	    const char *str;
	    unsigned int medianr;
	
	    create_considered(pool, repo, &c);
	    EXTEND(SP, 2 * repo->nsolvables);
	    FOR_REPO_SOLVABLES(repo, p, s)
	      {
		if (!MAPTST(&c, p))
		  continue;
		/* ignore dod packages */
		str = solvable_lookup_str(s, buildservice_id);
		if (str && !strcmp(str, "dod"))
		  continue;
		str = solvable_get_location(pool->solvables + p, &medianr);
		if (!str)
		  continue;
		PUSHs(sv_2mortal(newSVpv(str, 0)));
		PUSHs(sv_2mortal(newSViv(p)));
	      }
	    map_free(&c);
	}

void
tofile(BSSolv::repo repo, char *filename)
    CODE:
	{
	    FILE *fp;
	    fp = fopen(filename, "w");
	    if (fp == 0)
	      croak("%s: %s\n", filename, Strerror(errno));
	    repo_write_filtered(repo, fp, myrepowritefilter, 0, 0);
	    if (fclose(fp))
	      croak("fclose: %s\n",  Strerror(errno));
	}

void
tofile_fd(BSSolv::repo repo, int fd)
    CODE:
	{
	    FILE *fp;
	    int fd2;
	    fd2 = dup(fd);
	    if (fd2 == -1)
	      croak("dup: %s\n", Strerror(errno));
	    fp = fdopen(fd2, "w");
	    if (fp == 0)
	      {
		int e = errno;
		close(fd2);
		croak("fdopen: %s\n", Strerror(e));
	      }
	    repo_write_filtered(repo, fp, myrepowritefilter, 0, 0);
	    if (fclose(fp))
	      {
		int e = errno;
		close(fd2);
		croak("fclose: %s\n",  Strerror(e));
	      }
	}

SV *
tostr(BSSolv::repo repo)
    CODE:
	{
	    FILE *fp;
	    char *buf;
	    size_t len;
	    fp = open_memstream(&buf, &len);
	    if (fp == 0)
	      croak("open_memstream: %s\n", Strerror(errno));
	    repo_write_filtered(repo, fp, myrepowritefilter, 0, 0);
	    if (fclose(fp))
	      croak("fclose: %s\n",  Strerror(errno));
	    RETVAL = newSVpvn(buf, len);
	    free(buf);
	}
    OUTPUT:
	RETVAL

int
updatefrombins(BSSolv::repo repo, char *dir, ...)
    CODE:
	{
	    Pool *pool = repo->pool;
	    int i;
	    Repodata *data = 0;
	    Hashtable ht;
	    Hashval h, hh, hm;
	    int dirty = 0;
	    Map reused;
	    int oldend = 0;
	    Id p, id;
	    Solvable *s;
	    STRLEN sl;
	    const char *oldcookie;

	    map_init(&reused, repo->end - repo->start);
	    if (repo_lookup_str(repo, SOLVID_META, buildservice_dodurl))
	      {
	        /* this is a dod repo. keep all dod packages. */
		FOR_REPO_SOLVABLES(repo, p, s)
		  {
		    const char *str = solvable_lookup_str(s, buildservice_id);
		    if (str && !strcmp(str, "dod"))
		      MAPSET(&reused, p - repo->start);
		  }
	      }
	    hm = mkmask(2 * repo->nsolvables + 1);
	    ht = solv_calloc(hm + 1, sizeof(*ht));
	    oldcookie = repo_lookup_str(repo, SOLVID_META, buildservice_repocookie);
	    if (oldcookie && !strcmp(oldcookie, REPOCOOKIE))
	      {
		FOR_REPO_SOLVABLES(repo, p, s)
		  {
		    const char *str = solvable_lookup_str(s, buildservice_id);
		    if (!str || !strcmp(str, "dod"))
		      continue;
		    h = strhash(str) & hm;
		    hh = HASHCHAIN_START;
		    while ((id = ht[h]) != 0)
		      h = HASHCHAIN_NEXT(h, hh, hm);
		    ht[h] = p;
		  }
	      }
	    if (repo->end != repo->start)
	      oldend = repo->end;

	    for (i = 2; i + 1 < items; i += 2)
	      {
		char *s = SvPV(ST(i), sl);
		char *sid = SvPV_nolen(ST(i + 1));
		if (sl < 4)
		  continue;
		if (strcmp(s + sl - 4, ".rpm")
                    && strcmp(s + sl - 4, ".deb")
#ifdef ARCH_ADD_WITH_PKGID
                    && (sl < 11 || strcmp(s + sl - 11, ".pkg.tar.gz"))
                    && (sl < 11 || strcmp(s + sl - 11, ".pkg.tar.xz"))
#endif
		   )
		if (sl > 10 && !strcmp(s + sl - 10, ".patch.rpm"))
		  continue;
		if (sl > 10 && !strcmp(s + sl - 10, ".nosrc.rpm"))
		  continue;
		if (sl > 8 && !strcmp(s + sl - 8, ".src.rpm"))
		  continue;
		h = strhash(sid) & hm;
		hh = HASHCHAIN_START;
		while ((id = ht[h]) != 0)
		  {
		    const char *str = solvable_lookup_str(pool->solvables + id, buildservice_id);
		    if (!strcmp(str, sid))
		      {
			/* check location */
			unsigned int medianr;
			str = solvable_get_location(pool->solvables + id, &medianr);
			if (str[0] == '.' && str[1] == '/')
			  str += 2;
			if (!strcmp(str, s))
		          break;
		      }
		    h = HASHCHAIN_NEXT(h, hh, hm);
		  }
		if (id)
		  {
		    /* same id and location, reuse old entry */
		    MAPSET(&reused, id - repo->start);
		  }
		else
		  {
		    /* add new entry */
		    dirty++;
		    if (!data)
		      data = repo_add_repodata(repo, 0);
		    repodata_addbin(data, dir, s, (int)sl, sid);
		  }
	      }
	    solv_free(ht);
	    if (oldcookie)
	      {
		if (strcmp(oldcookie, REPOCOOKIE) != 0)
		  {
		    Repodata *firstrepodata = repo_id2repodata(repo, 1);
		    if (data && data != firstrepodata)
		      repodata_internalize(data);
		    data = firstrepodata;
		    repodata_set_str(data, SOLVID_META, buildservice_repocookie, REPOCOOKIE);
		  }
	      }
	    else
	      {
	        if (!data)
	          data = repo_add_repodata(repo, 0);
	        repodata_set_str(data, SOLVID_META, buildservice_repocookie, REPOCOOKIE);
	      }
	    if (data)
	      repodata_internalize(data);
	    if (oldend)
	      {
		for (i = repo->start; i < oldend; i++)
		  {
		    if (pool->solvables[i].repo != repo)
		      continue;
		    if (MAPTST(&reused, i - repo->start))
		      continue;
		    if (dirty <= 0)
		      dirty--;
		    repo_free_solvable_block(repo, i, 1, 0);
		  }
	      }
	    map_free(&reused);
	    RETVAL = dirty;
	}
    OUTPUT:
	RETVAL


void
getpathid(BSSolv::repo repo)
    PPCODE:
	{
	    Id p;
	    Solvable *s;
	    EXTEND(SP, repo->nsolvables * 2);
	    FOR_REPO_SOLVABLES(repo, p, s)
	      {
		unsigned int medianr;
		const char *str;
		str = solvable_get_location(s, &medianr);
		PUSHs(sv_2mortal(newSVpv(str, 0)));
		str = solvable_lookup_str(s, buildservice_id);
		PUSHs(sv_2mortal(newSVpv(str, 0)));
	      }
	}

const char *
name(BSSolv::repo repo)
    CODE:
	RETVAL = repo->name;
    OUTPUT:
	RETVAL

int
isexternal(BSSolv::repo repo)
    CODE:
	RETVAL = repo_lookup_void(repo, SOLVID_META, buildservice_external) ? 1 : 0;
    OUTPUT:
	RETVAL

const char *
dodurl(BSSolv::repo repo)
    CODE:
	RETVAL = repo_lookup_str(repo, SOLVID_META, buildservice_dodurl);
    OUTPUT:
	RETVAL

const char *
dodcookie(BSSolv::repo repo)
    CODE:
	RETVAL = repo_lookup_str(repo, SOLVID_META, buildservice_dodcookie);
    OUTPUT:
	RETVAL

void
updatedoddata(BSSolv::repo repo, HV *rhv = 0)
    CODE:
	{
	    Id p;
	    Solvable *s;
	    Repodata *data;
	    /* delete old dod data */
	    FOR_REPO_SOLVABLES(repo, p, s)
	      {
		const char *str = solvable_lookup_str(s, buildservice_id);
		if (!str || !strcmp(str, "dod"))
		    repo_free_solvable(repo, p, 1);
	      }
	    data = repo_add_repodata(repo, REPO_REUSE_REPODATA);
	    repodata_unset(data, SOLVID_META, buildservice_dodurl);
	    repodata_unset(data, SOLVID_META, buildservice_dodcookie);
	    /* add new data */
	    if (rhv)
		data2solvables(repo, data, rhv);
	    repo_internalize(repo);
	}


MODULE = BSSolv		PACKAGE = BSSolv::expander	PREFIX = expander


BSSolv::expander
new(char *packname = "BSSolv::expander", BSSolv::pool pool, HV *config)
    CODE:
	{
	    SV *sv, **svp;
	    char *str;
	    int i, neg;
	    Id id, id2;
	    Expander *xp;

	    xp = calloc(sizeof(Expander), 1);
	    xp->pool = pool;
	    svp = hv_fetch(config, "prefer", 6, 0);
	    sv = svp ? *svp : 0;
	    if (sv && SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVAV)
	      {
		AV *av = (AV *)SvRV(sv);
		for (i = 0; i <= av_len(av); i++)
		  {
		    svp = av_fetch(av, i, 0);
		    if (!svp)
		      continue;
		    sv = *svp;
		    str = SvPV_nolen(sv);
		    if (!str)
		      continue;
		    neg = 0;
		    if (*str == '-')
		      {
			neg = 1;
			str++;
		      }
		    id = pool_str2id(pool, str, 1);
		    id2 = 0;
		    if ((str = strchr(str, ':')) != 0)
		      id2 = pool_str2id(pool, str + 1, 1);
		    if (neg)
		      {
			MAPEXP(&xp->preferneg, id);
			MAPSET(&xp->preferneg, id);
		        if (id2)
			  {
			    MAPEXP(&xp->prefernegx, id2);
			    MAPSET(&xp->prefernegx, id2);
			  }
		      }
		    else
		      {
			queue_push(&xp->preferposq, id);
			MAPEXP(&xp->preferpos, id);
			MAPSET(&xp->preferpos, id);
		        if (id2)
			  {
			    MAPEXP(&xp->preferposx, id2);
			    MAPSET(&xp->preferposx, id2);
			  }
		      }
		  }
	      }
	    svp = hv_fetch(config, "ignoreh", 7, 0);
	    sv = svp ? *svp : 0;
	    if (sv && SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVHV)
	      {
		HV *hv = (HV *)SvRV(sv);
		HE *he;

		hv_iterinit(hv);
		while ((he = hv_iternext(hv)) != 0)
		  {
		    I32 strl;
		    str = hv_iterkey(he, &strl);
		    if (!str)
		      continue;
		 
		    id = pool_str2id(pool, str, 1);
		    id2 = 0;
		    if ((str = strchr(str, ':')) != 0)
		      id2 = pool_str2id(pool, str + 1, 1);
		    MAPEXP(&xp->ignored, id);
		    MAPSET(&xp->ignored, id);
		    if (id2)
		      {
			MAPEXP(&xp->ignoredx, id2);
		        MAPSET(&xp->ignoredx, id2);
		      }
		  }
	      }
	    svp = hv_fetch(config, "conflict", 8, 0);
	    sv = svp ? *svp : 0;
	    if (sv && SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVAV)
	      {
		AV *av = (AV *)SvRV(sv);
		for (i = 0; i <= av_len(av); i++)
		  {
		    char *p;
		    Id id2;

		    svp = av_fetch(av, i, 0);
		    if (!svp)
		      continue;
		    sv = *svp;
		    str = SvPV_nolen(sv);
		    if (!str)
		      continue;
		    p = strchr(str, ':');
		    if (!p)
		      continue;
		    id = pool_strn2id(pool, str, p - str, 1);
		    str = p + 1;
		    while ((p = strchr(str, ',')) != 0)
		      {
			id2 = pool_strn2id(pool, str, p - str, 1);
			queue_push2(&xp->conflictsq, id, id2);
			MAPEXP(&xp->conflicts, id);
			MAPSET(&xp->conflicts, id);
			MAPEXP(&xp->conflicts, id2);
			MAPSET(&xp->conflicts, id2);
			str = p + 1;
		      }
		    id2 = pool_str2id(pool, str, 1);
		    queue_push2(&xp->conflictsq, id, id2);
		    MAPEXP(&xp->conflicts, id);
		    MAPSET(&xp->conflicts, id);
		    MAPEXP(&xp->conflicts, id2);
		    MAPSET(&xp->conflicts, id2);
		  }
	      }
	    /* XXX: this modifies the pool, which is a bit unclean! */
	    svp = hv_fetch(config, "fileprovides", 12, 0);
	    sv = svp ? *svp : 0;
	    if (sv && SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVHV)
	      {
		HV *hv = (HV *)SvRV(sv);
		I32 strl;
		Queue q;

		xp->havefileprovides = 1;
		hv_iterinit(hv);
		queue_init(&q);
		while ((sv = hv_iternextsv(hv, &str, &strl)) != 0)
		  {
		    AV *av;
		    Id p, pp;
		    int havenew = 0;

		    if (!SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVAV)
		      continue;
		    id = pool_str2id(pool, str, 1);
		    queue_empty(&q);
		    FOR_PROVIDES(p, pp, id)
		      queue_push(&q, p);
		    av = (AV *)SvRV(sv);
		    for (i = 0; i <= av_len(av); i++)
		      {
			svp = av_fetch(av, i, 0);
			if (!svp)
			  continue;
			sv = *svp;
			str = SvPV_nolen(sv);
			if (!str)
			  continue;
			id2 = pool_str2id(pool, str, 0);
			FOR_PROVIDES(p, pp, id2)
			  {
			    int j;
			    for (j = 0; j < q.count; j++)
			      {
				if (q.elements[j] == p)
				  break;
				if (q.elements[j] > p)
				  {
				    queue_insert(&q, j, p);
				    havenew = 1;
				    break;
				  }
			      }
			    if (j == q.count)
			      {
			        queue_push(&q, p);
				havenew = 1;
			      }
			  }
		      }
		    if (havenew)
		      pool->whatprovides[id] = pool_queuetowhatprovides(pool, &q);
		  }
		queue_free(&q);
	      }
	    svp = hv_fetch(config, "expandflags:ignoreconflicts", 27, 0);
	    sv = svp ? *svp : 0;
	    if (sv && SvTRUE(sv))
	      xp->ignoreconflicts = 1;
	    svp = hv_fetch(config, "expand_dbg", 10, 0);
	    sv = svp ? *svp : 0;
	    if (sv && SvTRUE(sv))
	      xp->debug = 1;
	    sv = get_sv("Build::expand_dbg", FALSE);
	    if (sv && SvTRUE(sv))
	      xp->debug = 1;
	    RETVAL = xp;
	}
    OUTPUT:
	RETVAL


void
expand(BSSolv::expander xp, ...)
    PPCODE:
	{
	    Pool *pool;
	    int i, nerrors;
	    Id id, who, conflbuf[16];
	    Queue revertignore, in, out, confl;
	    int oldignoreignore = xp->ignoreignore;
	    int ignoreignore = 0;
	    Map oldignored, oldignoredx;
	    int ignoremapssaved = 0;

	    queue_init(&revertignore);
	    queue_init(&in);
	    queue_init(&out);
	    queue_init_buffer(&confl, conflbuf, sizeof(conflbuf)/sizeof(*conflbuf));
	    pool = xp->pool;
	    if (xp->debug)
	      expander_dbg(xp, "expand args:");
	    for (i = 1; i < items; i++)
	      {
		char *s = SvPV_nolen(ST(i));
		if (xp->debug)
		  expander_dbg(xp, " %s", s);
		if (*s == '-')
		  {
		    Id id;
		    if (s[1] == '-' && !strcmp(s, "--ignoreignore--"))
		      {
		        ignoreignore = 1;
		        continue;
		      }
		    id = pool_str2id(pool, s + 1, 1);
		    if (id == expander_directdepsend)
		      {
			queue_push(&in, id);
			continue;
		      }
		    queue_push(&revertignore, id);
		  }
		else if (*s == '!')
		  {
		    Id id = dep2id(pool, s + (s[1] == '!' ? 2 : 1));
		    queue_push2(&confl, id, s[1] == '!' ? 1 : 0);
		  }
		else
		  {
		    Id id = dep2id(pool, s);
		    queue_push(&in, id);
		  }
	      }
	    if (xp->debug)
	      expander_dbg(xp, "\n");

	    if (ignoreignore && revertignore.count)
	      {
		/* bad: have direct ignores and project config ignores */
		oldignored = xp->ignored;
		oldignoredx = xp->ignoredx;
		ignoremapssaved = 1;
		/* clear project config maps */
		memset(&xp->ignored, 0, sizeof(xp->ignored));
		memset(&xp->ignoredx, 0, sizeof(xp->ignoredx));
	      }

	    if (revertignore.count)
	      {
		/* mix direct ignores with ignores from project config */
	        int revertcnt = revertignore.count;
		for (i = 0; i < revertcnt; i++)
		  {
		    const char *ss;
		    id = revertignore.elements[i];
		    MAPEXP(&xp->ignored, id);
		    if (MAPTST(&xp->ignored, id))
		      continue;
		    MAPSET(&xp->ignored, id);
		    queue_push(&revertignore, id);
		    if ((ss = strchr(pool_id2str(pool, id), ':')) != 0)
		      {
			id = pool_str2id(pool, ss + 1, 1);
			MAPEXP(&xp->ignoredx, id);
			if (MAPTST(&xp->ignoredx, id))
			  continue;
			MAPSET(&xp->ignoredx, id);
			queue_push(&revertignore, -id);
		      }
		  }
		queue_deleten(&revertignore, 0, revertcnt);
	      }
	    else if (ignoreignore)
	      {
		/* no direct ignores, disable ignore processing */
	        xp->ignoreignore = 1;
	      }

	    MAPEXP(&xp->ignored, pool->ss.nstrings);
	    MAPEXP(&xp->ignoredx, pool->ss.nstrings);
	    MAPEXP(&xp->preferpos, pool->ss.nstrings);
	    MAPEXP(&xp->preferposx, pool->ss.nstrings);
	    MAPEXP(&xp->preferneg, pool->ss.nstrings);
	    MAPEXP(&xp->prefernegx, pool->ss.nstrings);
	    MAPEXP(&xp->conflicts, pool->ss.nstrings);

	    nerrors = expander_expand(xp, &in, &out, &confl);

	    /* revert ignores */
	    xp->ignoreignore = oldignoreignore;
	    if (ignoremapssaved)
	      {
		map_free(&xp->ignored);
		map_free(&xp->ignoredx);
		xp->ignored = oldignored;
		xp->ignoredx = oldignoredx;
	      }
	    else
	      {
		for (i = 0; i < revertignore.count; i++)
		  {
		    id = revertignore.elements[i];
		    if (id > 0)
		      MAPCLR(&xp->ignored, id);
		    else
		      MAPCLR(&xp->ignoredx, -id);
		  }
	      }
	    queue_free(&revertignore);

	    queue_free(&in);
	    queue_free(&confl);

	    if (nerrors)
	      {
		EXTEND(SP, nerrors + 1);
		PUSHs(sv_2mortal(newSV(0)));
		for (i = 0; i < out.count; )
		  {
		    SV *sv;
		    Id type = out.elements[i];
		    if (type == ERROR_NOPROVIDER)
		      {
			id = out.elements[i + 1];
			who = out.elements[i + 2];
			if (who)
		          sv = newSVpvf("nothing provides %s needed by %s", pool_dep2str(pool, id), pool_id2str(pool, pool->solvables[who].name));
			else
		          sv = newSVpvf("nothing provides %s", pool_dep2str(pool, id));
			i += 3;
		      }
		    else if (type == ERROR_CONFLICTINGPROVIDER)
		      {
			id = out.elements[i + 1];
			who = out.elements[i + 2];
			if (who)
		          sv = newSVpvf("conflict for provider of %s needed by %s", pool_dep2str(pool, id), pool_id2str(pool, pool->solvables[who].name));
			else
		          sv = newSVpvf("conflict for provider of %s", pool_dep2str(pool, id));
			i += 3;
		      }
		    else if (type == ERROR_CONFLICTINGPROVIDERS)
		      {
			id = out.elements[i + 1];
			who = out.elements[i + 2];
			if (who)
			  sv = newSVpvf("conflict for all providers of %s needed by %s", pool_dep2str(pool, id), pool_id2str(pool, pool->solvables[who].name));
			else
			  sv = newSVpvf("conflict for all providers of %s", pool_dep2str(pool, id));
			i += 3;
		      }
		    else if (type == ERROR_PROVIDERINFO)
		      {
			Id who2 = out.elements[i + 2];
			who = out.elements[i + 1];
			if (who2 < 0)
		          sv = newSVpvf("(provider %s obsoletes installed %s)", pool_id2str(pool, pool->solvables[who].name), pool_id2str(pool, pool->solvables[-who2].name));
			else
		          sv = newSVpvf("(provider %s conflicts with installed %s)", pool_id2str(pool, pool->solvables[who].name), pool_id2str(pool, pool->solvables[who2].name));
			i += 3;
		      }
		    else if (type == ERROR_PROVIDERINFO2)
		      {
			Id who2 = out.elements[i + 2];
			who = out.elements[i + 1];
			if (who2 < 0)
		          sv = newSVpvf("(provider %s is obsoleted by installed %s)", pool_id2str(pool, pool->solvables[who].name), pool_id2str(pool, pool->solvables[-who2].name));
			else if (who2 > 0)
		          sv = newSVpvf("(provider %s is conflicted by installed %s)", pool_id2str(pool, pool->solvables[who].name), pool_id2str(pool, pool->solvables[who2].name));
			else
		          sv = newSVpvf("(provider %s is conflicted by the build config)", pool_id2str(pool, pool->solvables[who].name));
			i += 3;
		      }
		    else if (type == ERROR_CHOICE)
		      {
			int j;
			char *str = "";
			for (j = i + 3; out.elements[j]; j++)
			  {
			    Solvable *s = pool->solvables + out.elements[j];
			    str = pool_tmpjoin(pool, str, " ", pool_id2str(pool, s->name));
			  }
			if (*str)
			  str++;	/* skip starting ' ' */
			id = out.elements[i + 1];
			who = out.elements[i + 2];
			if (who)
		          sv = newSVpvf("(BSSolve 2.2) have choice for %s needed by %s: %s", pool_dep2str(pool, id), pool_id2str(pool, pool->solvables[who].name), str);
			else
		          sv = newSVpvf("(BSSolve 2.2) have choice for %s: %s", pool_dep2str(pool, id), str);
			i = j + 1;
		      }
		    else
		      croak("expander: bad error type\n");
		    PUSHs(sv_2mortal(sv));
		  }
	      }
	    else
	      {
		EXTEND(SP, out.count + 1);
		PUSHs(sv_2mortal(newSViv((IV)1)));
		for (i = 0; i < out.count; i++)
		  {
		    Solvable *s = pool->solvables + out.elements[i];
		    PUSHs(sv_2mortal(newSVpv(pool_id2str(pool, s->name), 0)));
		  }
	      }
	    queue_free(&out);
	}

const char *
debugstr(BSSolv::expander xp)
    CODE:
	if (!xp->debugstr)
	  xp->debugstr = calloc(1, 1);
	RETVAL = xp->debugstr;
    OUTPUT:
	RETVAL


void
DESTROY(BSSolv::expander xp)
    CODE:
	map_free(&xp->ignored);
	map_free(&xp->ignoredx);
	queue_free(&xp->preferposq);
	map_free(&xp->preferpos);
	map_free(&xp->preferposx);
	map_free(&xp->preferneg);
	map_free(&xp->prefernegx);
	queue_free(&xp->conflictsq);
	map_free(&xp->conflicts);
	solv_free(xp->debugstr);
	solv_free(xp);
