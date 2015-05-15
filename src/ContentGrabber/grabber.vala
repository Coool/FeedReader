public class FeedReader.Grabber : GLib.Object {
    private string m_articleURL;
    private string m_rawHtml;
    private string m_nexPageURL;
    private GrabberConfig m_config;
    private bool m_firstPage;
    private string m_hostName;
    private bool m_configFound;
    private Xml.Doc* m_doc;
    private Xml.Node* m_root;
    private Xml.Ns* m_ns;


    public string m_author;
    public string m_title;
    public string m_date;
    public string m_html;

    public Grabber(string articleURL)
    {
        m_configFound = false;
        m_articleURL = articleURL;
        m_firstPage = true;
        m_hostName = grabberUtils.buildHostName(articleURL);

        string filename = "/usr/share/FeedReader/GrabberConfig/" + m_hostName + ".txt";
        if(FileUtils.test(filename, GLib.FileTest.EXISTS))
        {
            m_config = new GrabberConfig(filename);
            m_configFound = true;
        }

        //m_config.print();
    }

    ~Grabber()
    {
        //delete m_doc;
        delete m_root;
        delete m_ns;
    }

    public bool process()
    {
        if(!m_configFound)
            return false;

        logger.print(LogMessage.DEBUG, "Grabber: config found");

        if(!download())
            return false;

        logger.print(LogMessage.DEBUG, "Grabber: download success");

        prepArticle();

        logger.print(LogMessage.DEBUG, "Grabber: empty article preped");

        if(!parse())
            return false;

        return true;
    }

    private bool download()
    {
        var session = new Soup.Session();
        var msg = new Soup.Message("GET", m_articleURL);
        session.send_message(msg);
        m_rawHtml = (string)msg.response_body.flatten().data;
        return true;
    }

    private bool parse()
    {
        m_nexPageURL = null;
        logger.print(LogMessage.DEBUG, "Grabber: start parsing");

        // replace strings before parsing html
        unowned GLib.List<StringReplace> replace = m_config.getReplace();
        if(replace.length() != 0)
        {
            foreach(StringReplace pair in replace)
            {
                m_rawHtml = m_rawHtml.replace(pair.getToReplace(), pair.getReplaceWith());
            }
        }

        logger.print(LogMessage.DEBUG, "Grabber: parse html");

        // mute stdout first
        //var old_stdout = (owned) stdout;
        //stdout = FileStream.open ("/dev/null", "w");
        //var old_stderr = (owned) stderr;
        //stderr = FileStream.open ("/dev/null", "w");

        // parse html
        var html_cntx = new Html.ParserCtxt();
        html_cntx.use_options(Html.ParserOption.NOERROR);
        var doc = html_cntx.read_doc(m_rawHtml, "");
        if (doc == null)
        {
    		return false;
    	}

        // unmute
        //stdout = (owned) old_stdout;
        //stderr = (owned) old_stderr;

        logger.print(LogMessage.DEBUG, "Grabber: html parsed");


        // get link to next page of article if there are more than one pages
        if(m_config.getXPathNextPageURL() != null)
        {
            logger.print(LogMessage.DEBUG, "Grabber: grab next page url");
            m_nexPageURL = grabberUtils.getURL(doc, m_config.getXPathNextPageURL());
        }

        // get link to single-page view if it exists and download that page
        if(m_config.getXPathSinglePageURL() != null)
        {
            logger.print(LogMessage.DEBUG, "Grabber: grab single page view");
            string url = grabberUtils.getURL(doc, m_config.getXPathSinglePageURL());
            if(url != "" && url != null)
            {
                m_articleURL = url;
                download();
                delete doc;
                doc = html_cntx.read_doc(m_rawHtml, "");
            }
        }

        // get the title from the html (useful if feed doesn't provide one)
        unowned GLib.List<string> title = m_config.getXPathTitle();
        if(title.length() != 0 && m_firstPage)
        {
            foreach(string xpath in title)
            {
                string tmptitle = grabberUtils.getValue(doc, xpath, m_firstPage);
                if(tmptitle != null)
                    m_title = tmptitle.chomp().chug();
            }
        }

        // get the author from the html (useful if feed doesn't provide one)
        unowned GLib.List<string> author = m_config.getXPathAuthor();
        if(author.length() != 0)
        {
            foreach(string xpath in author)
            {
                string tmpAuthor = grabberUtils.getValue(doc, xpath);
                if(tmpAuthor != null)
                    m_author = tmpAuthor.chomp().chug();
            }
        }

        // get the date from the html (useful if feed doesn't provide one)
        unowned GLib.List<string> date = m_config.getXPathDate();
        if(date.length() != 0)
        {
            foreach(string xpath in date)
            {
                string tmpDate = grabberUtils.getValue(doc, xpath);
                if(tmpDate != null)
                    m_date = tmpDate.chomp().chug();
            }
        }

        // strip junk
        unowned GLib.List<string> strip = m_config.getXPathStrip();
        if(strip.length() != 0)
        {
            foreach(string xpath in strip)
            {
                grabberUtils.stripNode(doc, xpath);
            }
        }

        // strip any element whose @id or @class contains this substring
        unowned GLib.List<string> _stripIDorClass = m_config.getXPathStripIDorClass();
        if(_stripIDorClass.length() != 0)
        {
            foreach(string IDorClass in _stripIDorClass)
            {
                grabberUtils.stripIDorClass(doc, IDorClass);
            }
        }

        //strip any <img> element where @src attribute contains this substring
        unowned GLib.List<string> stripImgSrc = m_config.getXPathStripImgSrc();
        if(stripImgSrc.length() != 0)
        {
            foreach(string ImgSrc in stripImgSrc)
            {
                grabberUtils.stripNode(doc, "//img[contains(@src,'%s')]".printf(ImgSrc));
            }
        }

        // strip elements using Readability.com and Instapaper.com ignore class names
		// .entry-unrelated and .instapaper_ignore
		// See https://www.readability.com/publishers/guidelines/#view-plainGuidelines
		// and http://blog.instapaper.com/post/730281947
        grabberUtils.stripNode(doc,
                "//*[contains(concat(' ',normalize-space(@class),' '),' entry-unrelated ') or contains(concat(' ',normalize-space(@class),' '),' instapaper_ignore ')]");


        // strip elements that contain style="display: none;"
        grabberUtils.stripNode(doc, "//*[contains(@style,'display:none')]");

        // strip all scripts
        grabberUtils.stripNode(doc, "//script");

        // strip all comments
        grabberUtils.stripNode(doc, "//comment()");



        unowned GLib.List<string> bodyList = m_config.getXPathBody();
        if(bodyList.length() != 0)
        {
            foreach(string bodyXPath in bodyList)
            {
                grabberUtils.extractBody(doc, bodyXPath, m_root);
            }
        }

        delete doc;

        m_firstPage = false;

        if(m_nexPageURL != null)
        {
            if(!m_nexPageURL.has_prefix("http"))
            {
                m_nexPageURL = grabberUtils.completeURL(m_nexPageURL, m_articleURL);
            }
            m_articleURL = m_nexPageURL;
            logger.print(LogMessage.DEBUG, "Grabber: next page url: %s".printf(m_nexPageURL));
            download();
            parse();
            return true;
        }

        return true;
    }

    private void prepArticle()
    {
        m_doc = new Xml.Doc("1.0");
        m_ns = new Xml.Ns(null, "", "article");
        m_ns->type = Xml.ElementType.ELEMENT_NODE;
        m_root = new Xml.Node(m_ns, "body");
        m_doc->set_root_element(m_root);
    }

    public void getArticle(ref string article)
    {
        m_doc->dump_memory(out article);
    }

    public void print()
    {
        if(m_title != null)
            logger.print(LogMessage.DEBUG, "Grabber: title: %s".printf(m_title));

        if(m_author != null)
            logger.print(LogMessage.DEBUG, "Grabber: author: %s".printf(m_author));

        if(m_date != null)
            logger.print(LogMessage.DEBUG, "Grabber: date: %s".printf(m_date));
    }

    public string getAuthor()
    {
        return m_author;
    }
}
