
    SELECT
        d_exposure.person_id,
        d_exposure.drug_concept_id,
        d_standard_concept.concept_name as standard_concept_name,
        d_standard_concept.concept_code as standard_concept_code,
        d_standard_concept.vocabulary_id as standard_vocabulary,
        d_exposure.drug_exposure_start_datetime,
        d_exposure.drug_exposure_end_datetime,
        d_exposure.verbatim_end_date,
        d_exposure.drug_type_concept_id,
        d_type.concept_name as drug_type_concept_name,
        d_exposure.stop_reason,
        d_exposure.refills,
        d_exposure.quantity,
        d_exposure.days_supply,
        d_exposure.sig,
        d_exposure.route_concept_id,
        d_route.concept_name as route_concept_name,
        d_exposure.lot_number,
        d_exposure.visit_occurrence_id,
        d_visit.concept_name as visit_occurrence_concept_name,
        d_exposure.drug_source_value,
        d_exposure.drug_source_concept_id,
        d_source_concept.concept_name as source_concept_name,
        d_source_concept.concept_code as source_concept_code,
        d_source_concept.vocabulary_id as source_vocabulary,
        d_exposure.route_source_value,
        d_exposure.dose_unit_source_value 
    FROM
        ( SELECT
            * 
        FROM
            `drug_exposure` d_exposure 
        WHERE
            (
                drug_concept_id IN (
                    SELECT
                        DISTINCT ca.descendant_id 
                    FROM
                        `cb_criteria_ancestor` ca 
                    JOIN
                        (
                            SELECT
                                DISTINCT c.concept_id       
                            FROM
                                `cb_criteria` c       
                            JOIN
                                (
                                    SELECT
                                        CAST(cr.id as string) AS id             
                                    FROM
                                        `cb_criteria` cr             
                                    WHERE
                                        concept_id IN (
                                            1510813, 1539403, 1545958, 1549686, 1551860, 1592085, 1592180, 40165636
                                        )             
                                        AND full_text LIKE '%_rank1]%'       
                                ) a 
                                    ON (
                                        c.path LIKE CONCAT('%.',
                                    a.id,
                                    '.%') 
                                    OR c.path LIKE CONCAT('%.',
                                    a.id) 
                                    OR c.path LIKE CONCAT(a.id,
                                    '.%') 
                                    OR c.path = a.id) 
                                WHERE
                                    is_standard = 1 
                                    AND is_selectable = 1
                                ) b 
                                    ON (
                                        ca.ancestor_id = b.concept_id
                                    )
                            )
                        )  
                        AND (
                            d_exposure.PERSON_ID IN (
                                SELECT
                                    distinct person_id  
                            FROM
                                `cb_search_person` cb_search_person  
                            WHERE
                                cb_search_person.person_id IN (
                                    SELECT
                                        person_id 
                                    FROM
                                        `cb_search_person` p 
                                    WHERE
                                        has_whole_genome_variant = 1 
                                ) 
                            )
                    )
                ) d_exposure 
            LEFT JOIN
                `concept` d_standard_concept 
                    ON d_exposure.drug_concept_id = d_standard_concept.concept_id 
            LEFT JOIN
                `concept` d_type 
                    ON d_exposure.drug_type_concept_id = d_type.concept_id 
            LEFT JOIN
                `concept` d_route 
                    ON d_exposure.route_concept_id = d_route.concept_id 
            LEFT JOIN
                `visit_occurrence` v 
                    ON d_exposure.visit_occurrence_id = v.visit_occurrence_id 
            LEFT JOIN
                `concept` d_visit 
                    ON v.visit_concept_id = d_visit.concept_id 
            LEFT JOIN
                `concept` d_source_concept 
                    ON d_exposure.drug_source_concept_id = d_source_concept.concept_id